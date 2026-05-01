-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_028_delete_employee_full_purge.sql
--
-- Avant : delete_employee ne supprimait QUE la ligne shop_memberships →
--         l'employé licencié pouvait toujours se connecter (le compte
--         auth.users restait actif). Bug critique de sécurité.
--
-- Après : si l'utilisateur n'a plus aucune autre membership active après
--         la suppression, on purge son profile + auth.users + identities
--         + sessions. Si l'utilisateur est encore membre d'une autre
--         boutique, on conserve son auth pour ne pas casser ses autres
--         accès.
-- ════════════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS public.delete_employee(TEXT, TEXT);
CREATE OR REPLACE FUNCTION public.delete_employee(
  p_shop_id TEXT,
  p_user_id TEXT
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $del_emp$
DECLARE
  v_target_uid     UUID;
  v_other_memships INT;
BEGIN
  -- Garde : seul un admin/owner du shop peut supprimer
  IF NOT public._is_shop_admin(p_shop_id) THEN
    RAISE EXCEPTION 'Réservé aux administrateurs de la boutique'
      USING ERRCODE = '42501';
  END IF;

  -- Garde : pas de suppression du propriétaire
  IF EXISTS (
    SELECT 1 FROM shops
     WHERE id::text       = p_shop_id
       AND owner_id::text = p_user_id
  ) THEN
    RAISE EXCEPTION 'Impossible de retirer le propriétaire de la boutique'
      USING ERRCODE = '23503';
  END IF;

  -- Supprimer la ligne membership de cette boutique
  DELETE FROM shop_memberships
   WHERE shop_id::text = p_shop_id
     AND user_id::text = p_user_id;

  -- Compter les memberships restantes de l'utilisateur (autres boutiques)
  SELECT COUNT(*) INTO v_other_memships
    FROM shop_memberships
   WHERE user_id::text = p_user_id;

  -- Si plus aucune autre membership → l'utilisateur n'a plus aucun accès
  -- métier dans Fortress → on purge son auth complet pour invalider toute
  -- tentative de reconnexion (login serveur impossible).
  IF v_other_memships = 0 THEN
    BEGIN
      v_target_uid := p_user_id::uuid;
    EXCEPTION WHEN OTHERS THEN
      RETURN; -- p_user_id pas un UUID valide → on s'arrête là
    END;

    -- Subscriptions
    BEGIN DELETE FROM subscriptions WHERE user_id::text = p_user_id;
    EXCEPTION WHEN undefined_table THEN NULL; END;

    -- Profile
    DELETE FROM profiles WHERE id::text = p_user_id;

    -- auth.* (identities, sessions, refresh_tokens, users…) via helper
    -- créé dans hotfix_022.
    BEGIN
      PERFORM public._purge_auth_user(v_target_uid);
    EXCEPTION WHEN OTHERS THEN
      -- Privilèges insuffisants ou autre erreur → on log mais on ne
      -- bloque pas la suppression côté boutique.
      RAISE WARNING '[delete_employee] purge auth user % failed: %',
          v_target_uid, SQLERRM;
    END;
  END IF;
END;
$del_emp$;

ALTER FUNCTION public.delete_employee(TEXT, TEXT) OWNER TO postgres;
GRANT EXECUTE ON FUNCTION public.delete_employee(TEXT, TEXT) TO authenticated;
