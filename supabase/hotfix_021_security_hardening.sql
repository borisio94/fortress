-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_021_security_hardening.sql
--
-- 1. Restreint exec_sql() aux super admins (au lieu de tout authenticated).
-- 2. Ajoute SET search_path à toutes les fonctions SECURITY DEFINER de
--    hotfix_018_employees pour mitiger les attaques par search_path
--    (CVE pattern : un attaquant créant une fonction homonyme dans un
--    schéma écrit la table système et la fait exécuter à la place).
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1. exec_sql limité aux super admins ─────────────────────────────────
--
-- ⚠ INCOMPATIBLE AVEC LE SYSTÈME DE MIGRATIONS DU CLIENT.
--   L'app applique ses migrations au démarrage via `exec_sql`. Tant que
--   la migration côté client existe, il faut laisser cette RPC ouverte
--   aux authenticated. À RÉACTIVER quand le push de migrations se fera
--   uniquement via CI/admin tool (pas depuis l'app utilisateur).
--
-- DROP FUNCTION IF EXISTS public.exec_sql(text);
-- CREATE OR REPLACE FUNCTION public.exec_sql(sql text)
-- RETURNS void
-- LANGUAGE plpgsql SECURITY DEFINER
-- SET search_path = public, pg_temp
-- AS $exec_sql$
-- BEGIN
--   IF NOT EXISTS (
--     SELECT 1 FROM profiles
--      WHERE id::text = auth.uid()::text
--        AND is_super_admin = true
--   ) THEN
--     RAISE EXCEPTION 'Réservé aux super administrateurs'
--       USING ERRCODE = '42501';
--   END IF;
--   EXECUTE sql;
-- END;
-- $exec_sql$;
--
-- REVOKE ALL ON FUNCTION public.exec_sql(text) FROM PUBLIC;
-- GRANT EXECUTE ON FUNCTION public.exec_sql(text) TO authenticated;

-- ── 2. SET search_path sur les RPCs hotfix_018_employees ────────────────
-- Note : `extensions` est inclus pour que les fonctions pgcrypto (crypt,
-- gen_salt, etc.) restent accessibles dans create_employee et autres
-- RPCs qui en dépendent. Sans ce schéma, on aurait l'erreur 42883
-- "function gen_salt(unknown) does not exist".
ALTER FUNCTION public._is_shop_admin(TEXT)
  SET search_path = public, extensions, pg_temp;

ALTER FUNCTION public.create_employee(TEXT, TEXT, TEXT, TEXT, JSONB, TEXT)
  SET search_path = public, extensions, pg_temp;

ALTER FUNCTION public.update_employee_permissions(TEXT, TEXT, JSONB)
  SET search_path = public, extensions, pg_temp;

ALTER FUNCTION public.update_employee_profile(TEXT, TEXT, TEXT, TEXT)
  SET search_path = public, extensions, pg_temp;

ALTER FUNCTION public.set_employee_status(TEXT, TEXT, TEXT)
  SET search_path = public, extensions, pg_temp;

ALTER FUNCTION public.delete_employee(TEXT, TEXT)
  SET search_path = public, extensions, pg_temp;

ALTER FUNCTION public.list_shop_employees(TEXT)
  SET search_path = public, extensions, pg_temp;

-- ── 3. Restreindre activity_logs INSERT au minimum nécessaire ────────────
-- Ancien : tout authenticated peut INSERT → spam possible.
-- Nouveau : seulement les fonctions SECURITY DEFINER (qui contournent RLS)
-- ou un user qui inscrit un log à son propre nom.
DROP POLICY IF EXISTS activity_logs_authenticated_write ON activity_logs;
CREATE POLICY activity_logs_authenticated_write ON activity_logs
  FOR INSERT
  WITH CHECK (
    actor_id::text = auth.uid()::text
    OR EXISTS (
      SELECT 1 FROM profiles
       WHERE id::text = auth.uid()::text
         AND is_super_admin = true
    )
  );
