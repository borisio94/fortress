-- ═══════════════════════════════════════════════════════════════════════════
-- Fortress — Bootstrap RPC
-- À exécuter UNE FOIS dans l'éditeur SQL Supabase.
-- Après ça, l'app Flutter peut pousser ses migrations via exec_sql.
-- ═══════════════════════════════════════════════════════════════════════════
--
-- ⚠️ SÉCURITÉ : exec_sql permet à tout utilisateur authentifié d'exécuter
-- du SQL arbitraire avec les droits SECURITY DEFINER. C'est un trou de
-- sécurité massif en production. Option plus sûre : restreindre à un rôle
-- dédié ou vérifier is_super_admin=true dans le corps. Conservé tel quel
-- ici conformément au cahier des charges.

CREATE OR REPLACE FUNCTION exec_sql(sql text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN EXECUTE sql; END; $$;

REVOKE ALL ON FUNCTION exec_sql FROM PUBLIC;
GRANT EXECUTE ON FUNCTION exec_sql TO authenticated;
