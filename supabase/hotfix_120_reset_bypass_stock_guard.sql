-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_120_reset_bypass_stock_guard.sql
--
-- Suite de hotfix_119_purge_bypass_stock_guard.sql.
--
-- Contexte :
--   hotfix_119 fait respecter au trigger `block_product_delete_with_stock`
--   (hotfix_083) deux flags de session « purge en cours » :
--     • app.bypass_owner_protection  → suppression de compte (déjà posé)
--     • app.bypass_stock_guard        → reset (posé ICI)
--
-- Problème couvert :
--   reset_shop_data() et reset_all_data() (hotfix_019) appellent
--   `_purge_shop_dependents`, qui fait `DELETE FROM products`. Si un produit
--   a encore du stock résiduel, le garde-fou stock REFUSE la suppression
--   (« produit_en_stock ») et tout le reset rollback — exactement le même
--   symptôme que sur la suppression de compte owner.
--
-- Correctif :
--   Les deux RPC posent `app.bypass_stock_guard = 'on'` (transaction-local,
--   3e argument `true`) AVANT d'appeler _purge_shop_dependents. Le trigger
--   stock (hotfix_119) laisse alors passer la suppression des produits, même
--   avec du stock résiduel — légitime puisqu'on vide/supprime tout.
--
--   Flag DÉDIÉ, distinct de app.bypass_owner_protection : un reset NE doit
--   PAS désactiver protect_owner_delete (reset_shop_data conserve la boutique
--   et le membership de son propriétaire).
--
-- Corps des fonctions = version canonique hotfix_019, À L'IDENTIQUE, à la
-- seule différence du `set_config` ajouté. Idempotent (DROP + CREATE).
-- ════════════════════════════════════════════════════════════════════════════

-- ── reset_shop_data(UUID) — vider une boutique sans la supprimer ─────────────
DROP FUNCTION IF EXISTS public.reset_shop_data(UUID);
CREATE FUNCTION public.reset_shop_data(p_shop_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET row_security = off
SET search_path = public, pg_temp
AS $reset_shop$
DECLARE
  v_owner_t TEXT;
  v_name    TEXT;
  v_shop_t  TEXT := p_shop_id::text;
BEGIN
  SELECT owner_id::text, name INTO v_owner_t, v_name
    FROM shops WHERE id::text = v_shop_t;

  IF v_owner_t IS NULL THEN
    RAISE EXCEPTION 'Boutique introuvable';
  END IF;

  IF v_owner_t <> auth.uid()::text AND NOT EXISTS (
    SELECT 1 FROM profiles
     WHERE id::text = auth.uid()::text AND is_super_admin = true
  ) THEN
    RAISE EXCEPTION 'Non autorisé : propriétaire ou super admin requis';
  END IF;

  -- Désactiver le garde-fou stock pour cette transaction : on vide la
  -- boutique, le stock résiduel sur les produits supprimés est attendu.
  PERFORM set_config('app.bypass_stock_guard', 'on', true);

  -- Purger toutes les dépendances de cette boutique
  PERFORM public._purge_shop_dependents(ARRAY[v_shop_t]);

  INSERT INTO activity_logs (
    actor_id, actor_email, action, target_type,
    target_id, target_label, shop_id, details
  )
  VALUES (
    auth.uid(),
    (SELECT email FROM auth.users WHERE id::text = auth.uid()::text),
    'shop_reset', 'shop', v_shop_t, v_name, p_shop_id,
    jsonb_build_object('at', now())
  );

  RETURN jsonb_build_object('shop_id', v_shop_t, 'reset', true);
END $reset_shop$;

REVOKE ALL ON FUNCTION public.reset_shop_data(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reset_shop_data(UUID) TO authenticated;

-- ── reset_all_data() — purge plateforme (super admin uniquement) ─────────────
DROP FUNCTION IF EXISTS public.reset_all_data();
CREATE FUNCTION public.reset_all_data()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET row_security = off
SET search_path = public, pg_temp
AS $reset_all$
DECLARE
  v_deleted_profiles INT := 0;
  v_deleted_auth     INT := 0;
  v_auth_error       TEXT := NULL;
  v_all_shops        TEXT[];
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM profiles
    WHERE id::text = auth.uid()::text AND is_super_admin = true
  ) THEN
    RAISE EXCEPTION 'Seul un super admin peut exécuter cette opération';
  END IF;

  -- Récupérer toutes les boutiques (de tout le monde)
  SELECT ARRAY(SELECT id::text FROM shops) INTO v_all_shops;

  -- Désactiver le garde-fou stock pour cette transaction (purge totale).
  PERFORM set_config('app.bypass_stock_guard', 'on', true);

  -- Purger toutes les dépendances
  PERFORM public._purge_shop_dependents(v_all_shops);

  -- Supprimer les boutiques
  DELETE FROM shops;

  -- Memberships restants (sécurité — devrait être vide après purge)
  BEGIN DELETE FROM shop_memberships;
  EXCEPTION WHEN undefined_table THEN NULL; END;

  BEGIN DELETE FROM subscriptions;
  EXCEPTION WHEN undefined_table THEN NULL; END;

  BEGIN DELETE FROM pending_invitations;
  EXCEPTION WHEN undefined_table THEN NULL; END;

  -- Profiles non super-admin
  WITH d AS (
    DELETE FROM profiles
    WHERE COALESCE(is_super_admin, false) = false
    RETURNING 1
  )
  SELECT COUNT(*) INTO v_deleted_profiles FROM d;

  -- auth.users non super-admin
  BEGIN
    WITH d AS (
      DELETE FROM auth.users
      WHERE id NOT IN (SELECT id FROM profiles WHERE is_super_admin = true)
      RETURNING 1
    )
    SELECT COUNT(*) INTO v_deleted_auth FROM d;
  EXCEPTION
    WHEN insufficient_privilege THEN
      v_auth_error := 'insufficient_privilege';
      RAISE WARNING
        '[reset_all_data] Impossible de supprimer auth.users — privilèges manquants. '
        'Changez l''OWNER de la fonction à postgres ou utilisez une Edge Function.';
    WHEN OTHERS THEN
      v_auth_error := SQLERRM;
      RAISE WARNING '[reset_all_data] Erreur auth.users : %', SQLERRM;
  END;

  INSERT INTO activity_logs (
    actor_id, actor_email, action, target_type, details
  )
  VALUES (
    auth.uid(),
    (SELECT email FROM auth.users WHERE id::text = auth.uid()::text),
    'platform_reset', 'platform',
    jsonb_build_object(
      'at', now(),
      'deleted_profiles', v_deleted_profiles,
      'deleted_auth_users', v_deleted_auth,
      'auth_error', v_auth_error
    )
  );

  RETURN jsonb_build_object(
    'deleted_profiles',   v_deleted_profiles,
    'deleted_auth_users', v_deleted_auth,
    'auth_error',         v_auth_error
  );
END $reset_all$;

ALTER FUNCTION public.reset_all_data() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.reset_all_data() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reset_all_data() TO authenticated;

NOTIFY pgrst, 'reload schema';
