-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_043_functions_hardening.sql
--
-- 🚨 HIGH — corrige en bulk 2 classes de warnings Supabase Advisor :
--   1. function_search_path_mutable : ajoute `SET search_path = public,
--      pg_temp` à toutes les fonctions public.* qui en manquent. Évite
--      l'attaque par search path injection (un user crée un schéma
--      malveillant et redirige les SELECT vers une fausse table).
--   2. public_can_execute_security_definer : REVOKE EXECUTE FROM PUBLIC
--      sur toutes les fonctions SECURITY DEFINER + GRANT à authenticated.
--      Empêche un anon non connecté d'invoquer une fonction qui s'exécute
--      avec les droits du créateur (postgres) → contournement total RLS.
--
-- NE corrige PAS : "Signed-In Users Can Execute SECURITY DEFINER" — ce
-- warning demande un audit manuel par fonction (chacune doit être validée
-- comme sûre pour les rôles `authenticated`). C'est souvent intentionnel.
--
-- 100% idempotent — ALTER FUNCTION et REVOKE/GRANT sont déjà idempotents.
-- ════════════════════════════════════════════════════════════════════════════


-- ── 1. SET search_path sur toutes les fonctions public.* qui n'en ont pas
DO $hardening_searchpath$
DECLARE
  r RECORD;
  cnt INT := 0;
BEGIN
  FOR r IN
    SELECT n.nspname, p.proname,
           pg_get_function_identity_arguments(p.oid) AS args
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.prokind = 'f'   -- functions seulement (exclut agrégats/procédures)
       AND (p.proconfig IS NULL
            OR NOT EXISTS (
              SELECT 1 FROM unnest(p.proconfig) AS c
               WHERE c LIKE 'search_path=%'
            ))
  LOOP
    EXECUTE format(
      'ALTER FUNCTION %I.%I(%s) SET search_path = public, pg_temp',
      r.nspname, r.proname, r.args
    );
    cnt := cnt + 1;
  END LOOP;
  RAISE NOTICE '[hotfix_043] search_path fixé sur % fonctions', cnt;
END
$hardening_searchpath$;


-- ── 2. REVOKE PUBLIC + GRANT authenticated sur SECURITY DEFINER
-- NB : `PUBLIC` est un mot-clé spécial Postgres, pas un nom de rôle. La
-- fonction `has_function_privilege('PUBLIC', ...)` lève "role PUBLIC does
-- not exist". Le bon test passe par `aclexplode(proacl)` où `grantee = 0`
-- est l'OID magique réservé à PUBLIC. Quand `proacl` est NULL, l'ACL est
-- au défaut Postgres : `EXECUTE` granté à PUBLIC.
DO $hardening_grants$
DECLARE
  r RECORD;
  cnt INT := 0;
BEGIN
  FOR r IN
    SELECT n.nspname, p.proname,
           pg_get_function_identity_arguments(p.oid) AS args
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.prokind = 'f'
       AND p.prosecdef = true
       AND (
         p.proacl IS NULL
         OR EXISTS (
           SELECT 1 FROM aclexplode(p.proacl) AS a
            WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE'
         )
       )
  LOOP
    EXECUTE format(
      'REVOKE EXECUTE ON FUNCTION %I.%I(%s) FROM PUBLIC',
      r.nspname, r.proname, r.args
    );
    EXECUTE format(
      'GRANT EXECUTE ON FUNCTION %I.%I(%s) TO authenticated',
      r.nspname, r.proname, r.args
    );
    cnt := cnt + 1;
  END LOOP;
  RAISE NOTICE '[hotfix_043] PUBLIC EXECUTE révoqué + authenticated granté sur % fonctions SECURITY DEFINER', cnt;
END
$hardening_grants$;


-- ── Vérification post-déploiement ──────────────────────────────────────────
-- Les 2 requêtes ci-dessous doivent renvoyer 0 ligne après le fix :
--
-- Nb fonctions encore sans search_path :
-- SELECT COUNT(*) FROM pg_proc p
--   JOIN pg_namespace n ON n.oid = p.pronamespace
--  WHERE n.nspname = 'public' AND p.prokind = 'f'
--    AND (p.proconfig IS NULL OR NOT EXISTS (
--      SELECT 1 FROM unnest(p.proconfig) c WHERE c LIKE 'search_path=%'));
--
-- Nb SECURITY DEFINER encore exécutables par PUBLIC :
-- SELECT COUNT(*) FROM pg_proc p
--   JOIN pg_namespace n ON n.oid = p.pronamespace
--  WHERE n.nspname = 'public' AND p.prokind = 'f'
--    AND p.prosecdef = true
--    AND (p.proacl IS NULL OR EXISTS (
--      SELECT 1 FROM aclexplode(p.proacl) a
--       WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE'));
