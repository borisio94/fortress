-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_040_lock_exec_sql.sql
--
-- 🚨 CRITIQUE — verrouille la RPC `exec_sql(sql text)` (créée par
-- bootstrap.sql) qui jusqu'ici exécutait du SQL arbitraire pour TOUT
-- utilisateur authentifié. Un caissier compromis pouvait `DROP TABLE`,
-- exfiltrer auth.users, etc.
--
-- Ce hotfix la restreint aux super-admins (profiles.is_super_admin=true).
-- Pour les autres utilisateurs, l'appel raise un 42501.
--
-- ⚠ Impact côté app Flutter :
--   `lib/core/database/supabase_migrations.dart::runIfNeeded()` appelle
--   `exec_sql` au démarrage. Après ce hotfix, les appels échoueront
--   pour les non-super-admins — mais le code Flutter wrap déjà tout
--   dans try/catch (cf. main.dart:25-27 et supabase_migrations.dart:29-56)
--   donc l'app continue de fonctionner.
--
-- 📋 Avant d'appliquer ce hotfix, s'assurer que TOUTES les migrations
-- (supabase/migrations/00*.sql) sont déjà appliquées en base. Sinon, les
-- pousser manuellement depuis le SQL Editor en tant que super-admin.
--
-- 100 % idempotent.
-- ════════════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS public.exec_sql(text);

CREATE FUNCTION public.exec_sql(sql text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $exec_sql$
BEGIN
  -- Garde : seul un super-admin peut exécuter du SQL arbitraire.
  IF NOT EXISTS (
    SELECT 1 FROM profiles
     WHERE id::text = auth.uid()::text
       AND COALESCE(is_super_admin, false) = TRUE
  ) THEN
    RAISE EXCEPTION
      'exec_sql réservé aux super-admins (privilèges insuffisants)'
      USING ERRCODE = '42501';
  END IF;

  EXECUTE sql;
END;
$exec_sql$;

ALTER FUNCTION public.exec_sql(text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.exec_sql(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exec_sql(text) TO authenticated;
-- Le GRANT reste à `authenticated` car la garde interne se charge du
-- filtrage. Avantage : le client Flutter n'a pas à gérer un nouveau type
-- d'erreur "function does not exist", il reçoit juste un 42501 qu'il
-- avale (try/catch déjà en place dans supabase_migrations.dart).


-- ── Vérification après application ───────────────────────────────────────
-- Test 1 : super-admin → OK
--   SELECT public.exec_sql('SELECT 1');
--   → attendu : exécution silencieuse
--
-- Test 2 : caissier (role='user') ou tout authenticated non super-admin
--   → SELECT public.exec_sql('DROP TABLE shops');
--   → attendu : ERROR 42501 "exec_sql réservé aux super-admins"
