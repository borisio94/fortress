-- hotfix_161_job_title_permissions.sql
-- ═════════════════════════════════════════════════════════════════════════
-- UN POSTE PORTE SES DROITS — `job_titles.permissions`.
--
-- hotfix_160 a fait des postes une liste de libellés appartenant à la
-- boutique. Il leur manquait l'essentiel : ce qu'un poste a le droit de faire.
-- « Chawarmier » n'a pas les mêmes accès que « Gérant », et les préréglages
-- livrés avec l'app (Admin, Employé, Comptable) ne couvrent pas les métiers
-- d'un restaurant camerounais.
--
-- Un poste devient donc un COUPLE : un nom de fonction et un profil de droits.
-- Le choisir à la création d'un compte coche les autorisations correspondantes
-- ET renseigne la fonction — les deux ne peuvent plus diverger.
--
-- FORMAT : liste de clés séparées par des virgules
-- (`inventory.view,caisse.access,…`), exactement les clés
-- `EmployeePermission.key` côté Dart. Pourquoi du texte et pas un tableau ni
-- du JSON : la file de synchronisation offline pousse des valeurs scalaires,
-- et une clé inconnue (permission retirée d'une version à l'autre) doit être
-- ignorable à la lecture sans faire échouer la ligne entière.
--
-- NULL = poste sans profil de droits. C'est le cas de tous les postes amorcés
-- par hotfix_160 : ils nomment une fonction, sans rien décider des accès. Les
-- sélectionner ne touche donc à aucune case.
--
-- 100 % idempotent (ré-exécutable sans effet de bord).
-- ═════════════════════════════════════════════════════════════════════════

ALTER TABLE public.job_titles
  ADD COLUMN IF NOT EXISTS permissions TEXT;

COMMENT ON COLUMN public.job_titles.permissions IS
  'Profil de droits du poste (hotfix_161) : clés EmployeePermission séparées '
  'par des virgules. NULL = le poste ne nomme qu''une fonction et ne décide '
  'd''aucun accès.';

-- ── Vérification ─────────────────────────────────────────────────────────
--
--   SELECT column_name, data_type
--     FROM information_schema.columns
--    WHERE table_name = 'job_titles' AND column_name = 'permissions';
--
--   -- Postes d'une boutique et nombre de droits par poste :
--   SELECT name,
--          CASE WHEN permissions IS NULL OR permissions = '' THEN 0
--               ELSE array_length(string_to_array(permissions, ','), 1)
--          END AS droits
--     FROM public.job_titles
--    WHERE shop_id = '<shop>'
--    ORDER BY name;
--
-- Fin — hotfix_161_job_title_permissions.sql
