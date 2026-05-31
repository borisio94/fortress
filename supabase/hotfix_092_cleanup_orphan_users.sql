-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_092_cleanup_orphan_users.sql
--
-- Bug : delete_employee (hotfix_028) ne purge auth.users + profile que si
-- v_other_memships = 0 AU MOMENT EXACT du delete. Si l'utilisateur avait
-- des memberships dans d'autres boutiques qui disparaissent ensuite par
-- cascade (ON DELETE shops), l'orphan reste indéfiniment dans auth.users
-- + profiles. Conséquence : un compte zombie peut se ré-authentifier
-- (SessionValidator côté client le détecte et force-logout, mais
-- l'email continue à occuper auth.users → impossible de recréer un
-- compte avec la même adresse).
--
-- Solution : trigger AFTER DELETE ON shop_memberships qui ré-évalue
-- l'état après chaque retrait — si l'utilisateur n'a plus aucune
-- membership ni shop owné (et n'est pas super-admin), purge complète.
-- Plus un cleanup ponctuel des orphans déjà accumulés.
--
-- Idempotent : DROP TRIGGER IF EXISTS + CREATE OR REPLACE FUNCTION.
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1. Nettoyage immédiat des orphans existants ─────────────────────────────
-- Liste : profils sans membership + sans shop owné + pas super-admin.
DO $cleanup_now$
DECLARE
  v_uid UUID;
BEGIN
  FOR v_uid IN
    SELECT p.id
      FROM profiles p
     WHERE COALESCE(p.is_super_admin, false) = false
       AND NOT EXISTS (
         SELECT 1 FROM shop_memberships m WHERE m.user_id::text = p.id::text
       )
       AND NOT EXISTS (
         SELECT 1 FROM shops s WHERE s.owner_id::text = p.id::text
       )
  LOOP
    BEGIN
      DELETE FROM subscriptions WHERE user_id::text = v_uid::text;
    EXCEPTION WHEN OTHERS THEN NULL; END;
    DELETE FROM profiles WHERE id = v_uid;
    BEGIN
      PERFORM public._purge_auth_user(v_uid);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING '[orphan cleanup] auth purge failed for %: %',
          v_uid, SQLERRM;
    END;
  END LOOP;
END $cleanup_now$;


-- ── 2. Trigger préventif : auto-purge en cas de cascade future ──────────────
CREATE OR REPLACE FUNCTION public._cleanup_orphan_on_membership_delete()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $cleanup_trg$
DECLARE
  v_memships  INT;
  v_owned     INT;
  v_is_sa     BOOLEAN;
  v_uid       UUID;
BEGIN
  -- Cast safe : si user_id n'est pas un UUID valide, on s'arrête.
  BEGIN
    v_uid := OLD.user_id::uuid;
  EXCEPTION WHEN OTHERS THEN
    RETURN OLD;
  END;

  -- Super-admin : jamais purgé automatiquement.
  SELECT COALESCE(is_super_admin, false) INTO v_is_sa
    FROM profiles WHERE id = v_uid;
  IF v_is_sa THEN RETURN OLD; END IF;

  -- Reste-t-il des memberships après cette suppression ?
  SELECT COUNT(*) INTO v_memships
    FROM shop_memberships WHERE user_id::text = OLD.user_id::text;
  IF v_memships > 0 THEN RETURN OLD; END IF;

  -- Possède-t-il encore une boutique en propre ?
  SELECT COUNT(*) INTO v_owned
    FROM shops WHERE owner_id::text = OLD.user_id::text;
  IF v_owned > 0 THEN RETURN OLD; END IF;

  -- Orphan confirmé → purge totale.
  BEGIN
    DELETE FROM subscriptions WHERE user_id::text = OLD.user_id::text;
  EXCEPTION WHEN OTHERS THEN NULL; END;
  DELETE FROM profiles WHERE id = v_uid;
  BEGIN
    PERFORM public._purge_auth_user(v_uid);
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING '[orphan trigger] auth purge failed for %: %',
        v_uid, SQLERRM;
  END;

  RETURN OLD;
END;
$cleanup_trg$;

DROP TRIGGER IF EXISTS trg_cleanup_orphan_user ON public.shop_memberships;
CREATE TRIGGER trg_cleanup_orphan_user
AFTER DELETE ON public.shop_memberships
FOR EACH ROW EXECUTE FUNCTION public._cleanup_orphan_on_membership_delete();

NOTIFY pgrst, 'reload schema';

-- ── Vérifications (à lancer séparément après run) ──────────────────────────
-- 1. Confirmer qu'il ne reste aucun profile orphan :
--   SELECT p.id, p.email
--     FROM profiles p
--    WHERE COALESCE(p.is_super_admin, false) = false
--      AND NOT EXISTS (SELECT 1 FROM shop_memberships WHERE user_id::text = p.id::text)
--      AND NOT EXISTS (SELECT 1 FROM shops WHERE owner_id::text = p.id::text);
--   → 0 lignes attendues
--
-- 2. Confirmer que le trigger est bien attaché :
--   SELECT tgname, tgtype, tgenabled FROM pg_trigger
--    WHERE tgrelid = 'public.shop_memberships'::regclass
--      AND tgname = 'trg_cleanup_orphan_user';
--   → 1 ligne attendue, tgenabled = 'O' (origin)
