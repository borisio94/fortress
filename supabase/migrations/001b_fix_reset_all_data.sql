-- ═══════════════════════════════════════════════════════════════════════════
-- 001b_fix_reset_all_data.sql  (RENOMMÉ — anciennement 002_fix_reset_all_data)
--
-- ⚠️  OBSOLÈTE — la fonction `reset_all_data()` définie ici a été REMPLACÉE
-- par la version définitive de `supabase/hotfix_019_purge_complete.sql` qui
-- ajoute aussi le purge des dépendances via `_purge_shop_dependents`.
--
-- Renommé en `001b_*` pour éliminer l'ambiguïté de tri alphabétique avec
-- `002_shop_admin_activity_policy.sql` (deux fichiers `002_*` en parallèle
-- causaient un risque d'application dans un ordre non-déterministe selon
-- l'environnement / les locales).
--
-- Ce fichier est conservé pour la rétrocompatibilité (environnements qui ne
-- recevront pas hotfix_019). Si vous avez déjà appliqué hotfix_019, vous
-- pouvez ignorer cette migration ou la supprimer du dossier sans impact.
--
-- Contexte historique : corrige le bug où `reset_all_data()` n'arrivait
-- pas à supprimer auth.users silencieusement, permettant à d'anciens
-- comptes propriétaires de se reconnecter après reset.
-- ═══════════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS reset_all_data();

CREATE FUNCTION reset_all_data()
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET row_security = off
AS $fn$
DECLARE
  v_deleted_profiles INT := 0;
  v_deleted_auth     INT := 0;
  v_auth_error       TEXT := NULL;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM profiles
    WHERE id = auth.uid() AND is_super_admin = true
  ) THEN
    RAISE EXCEPTION 'Seul un super admin peut exécuter cette opération';
  END IF;

  DELETE FROM orders           WHERE true;
  DELETE FROM products         WHERE true;
  DELETE FROM categories       WHERE true;
  DELETE FROM clients          WHERE true;
  DELETE FROM shop_memberships WHERE true;
  DELETE FROM shops            WHERE true;
  DELETE FROM subscriptions    WHERE true;

  WITH d AS (
    DELETE FROM profiles
    WHERE COALESCE(is_super_admin, false) = false
    RETURNING 1
  )
  SELECT COUNT(*) INTO v_deleted_profiles FROM d;

  -- Supprimer les auth.users non-super-admin.
  -- On capture toute erreur pour la remonter à l'app au lieu de l'avaler.
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
        'Changez l''OWNER de la fonction à postgres ou utilisez une Edge Function '
        'avec service_role_key pour supprimer les comptes Supabase Auth.';
    WHEN OTHERS THEN
      v_auth_error := SQLERRM;
      RAISE WARNING '[reset_all_data] Erreur auth.users : %', SQLERRM;
  END;

  INSERT INTO activity_logs (actor_id, actor_email, action, target_type, details)
  VALUES (
    auth.uid(),
    (SELECT email FROM auth.users WHERE id = auth.uid()),
    'platform_reset',
    'platform',
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
END $fn$;

-- Donner le privilège maximum à la fonction
ALTER FUNCTION reset_all_data() OWNER TO postgres;
REVOKE ALL ON FUNCTION reset_all_data() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION reset_all_data() TO authenticated;

-- Grant explicite — nécessaire sur certaines offres Supabase
DO $$
BEGIN
  GRANT DELETE ON auth.users TO postgres;
EXCEPTION WHEN insufficient_privilege THEN NULL;
END $$;
