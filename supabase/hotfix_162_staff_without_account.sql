-- hotfix_162_staff_without_account.sql
-- ═════════════════════════════════════════════════════════════════════════
-- DU PERSONNEL QUI NE SE CONNECTE JAMAIS — `employees.has_app_access`.
--
-- Un restaurant emploie deux populations que la fiche Personnel confondait :
--   * celles qui utilisent l'application — serveurs qui prennent les
--     commandes, caissiers, gérants. Leur fiche est rattachée à un compte,
--     dont elle recopie le nom et la fonction ;
--   * celles qui ne s'y connecteront JAMAIS — veilleur de nuit, homme de
--     ménage, plongeur. Pas de compte, pas de mot de passe, mais un salaire,
--     des heures et des avances à tenir.
--
-- La seconde était impossible à inscrire : la fiche imposait de choisir la
-- personne parmi les comptes de la boutique. Créer un compte à un veilleur
-- pour pouvoir lui verser son salaire aurait consommé un siège d'employé de
-- l'abonnement, et ouvert un accès dont personne n'a besoin.
--
-- Le drapeau ne fait pas que classer : il décide où se saisissent le nom et
-- la fonction. Avec compte, ils sont HÉRITÉS (jamais retapés, donc jamais
-- divergents) ; sans compte, ils se saisissent sur la fiche, puisque aucun
-- compte ne les porte.
--
-- DÉFAUT `true` : toute fiche antérieure vient forcément d'un compte, c'était
-- la seule façon d'en créer une. Identique à la migration de schéma v2 côté
-- Dart (`StaffMember._markLegacyAsAccountHolder`).
--
-- 100 % idempotent (ré-exécutable sans effet de bord).
-- ═════════════════════════════════════════════════════════════════════════

ALTER TABLE public.employees
  ADD COLUMN IF NOT EXISTS has_app_access BOOLEAN NOT NULL DEFAULT true;

COMMENT ON COLUMN public.employees.has_app_access IS
  'La personne a-t-elle un compte dans l''application (hotfix_162) ? false = '
  'personnel seul (veilleur, homme de ménage…) : salaire, pointage et paie '
  'sont tenus ici, sans aucun accès à l''app.';

-- ── Vérification ─────────────────────────────────────────────────────────
--
--   SELECT column_name, column_default, is_nullable
--     FROM information_schema.columns
--    WHERE table_name = 'employees' AND column_name = 'has_app_access';
--
--   -- Répartition des deux populations, par boutique :
--   SELECT shop_id,
--          count(*) FILTER (WHERE has_app_access)     AS avec_compte,
--          count(*) FILTER (WHERE NOT has_app_access) AS personnel_seul
--     FROM public.employees
--    GROUP BY shop_id;
--
-- Fin — hotfix_162_staff_without_account.sql
