-- hotfix_182_employees_user_id.sql
-- ═════════════════════════════════════════════════════════════════════════
-- PERSONNEL — la fiche sait enfin à QUEL COMPTE elle appartient.
--
-- Une fiche de personnel se crée de deux façons : SAISIE à la main pour qui
-- ne se connectera jamais (veilleur, plongeur), ou CHOISIE parmi les comptes
-- de la boutique pour qui utilise l'application.
--
-- Dans le second cas, aucun lien n'était conservé. Le rapprochement se faisait
-- sur le NOM, en minuscules, et le code le reconnaissait lui-même
-- (`restaurant_staff_page.dart` : « c'est imparfait — deux homonymes seraient
-- confondus »).
--
-- ── CE QUE ÇA CASSE, CONCRÈTEMENT ──────────────────────────────────────────
--
-- La liste des comptes proposés retire ceux qui ont déjà leur fiche. Avec deux
-- « Awa Ndiaye » dans l'équipe, la première fiche créée fait DISPARAÎTRE la
-- seconde de la liste : son compte devient inéligible, et le gérant n'a aucun
-- moyen de lui créer sa fiche — ni de comprendre pourquoi.
--
-- Le dédoublonnage des fiches, lui, n'a jamais reposé sur le nom : il compare
-- le code de pointage et le numéro de téléphone, et `staff_service.dart` écrit
-- pourquoi — « le nom ne suffit pas à les rapprocher, et deux homonymes
-- existent vraiment ». L'écran du personnel n'avait simplement pas suivi cette
-- règle, faute de pouvoir le faire.
--
-- ── POURQUOI PAS LE TÉLÉPHONE, PUISQU'IL SERT DÉJÀ AILLEURS ────────────────
--
-- Parce que le compte n'en porte pas. `Employee` — la vue d'un membre de la
-- boutique — expose `userId`, `fullName`, `email` et `jobTitle`. Pas de
-- téléphone. La seule clé partagée par les deux notions est l'identifiant du
-- compte, et c'est cette colonne.
--
-- ⚠ CE FICHIER S'APPLIQUE AVANT LE DÉPLOIEMENT DU CLIENT.
-- Une fois déployé, `StaffMember.toMap` envoie `user_id`. Sans la colonne,
-- PostgREST rejette l'écriture ENTIÈRE (PGRST204) : ce n'est pas le lien qui
-- manquerait, c'est la fiche de personnel qui ne partirait plus.
--
-- ADD COLUMN sans défaut : métadonnée seule, aucune réécriture de table.
-- 100 % idempotent.
--
-- PAS DE CONTRAINTE D'UNICITÉ, et c'est délibéré. Une boutique peut vouloir
-- deux fiches pour un même compte — un employé qui change de poste en gardant
-- l'ancienne archivée. C'est le dédoublonnage applicatif, sur code et
-- téléphone, qui tranche ; une contrainte ici refuserait des cas légitimes au
-- moment le moins opportun, en plein service.
--
-- PAS DE CLÉ ÉTRANGÈRE non plus : `employees` est synchronisée depuis des
-- appareils hors ligne, et une fiche peut arriver avant que le profil du
-- compte ait été répliqué. Une FK ferait échouer la remontée d'une fiche
-- créée en coupure — exactement le cas que l'offline-first doit absorber.
-- ═════════════════════════════════════════════════════════════════════════

ALTER TABLE public.employees
  ADD COLUMN IF NOT EXISTS user_id TEXT;

COMMENT ON COLUMN public.employees.user_id IS
  'Compte auquel cette fiche de personnel correspond, quand elle a été créée '
  'à partir d''un compte de la boutique. NULL pour le personnel sans accès à '
  'l''application (veilleur, plongeur), qui est saisi à la main.';

-- Lecture courante : « ce compte a-t-il déjà une fiche dans cette boutique ? »
-- posée à chaque ouverture du formulaire de personnel.
CREATE INDEX IF NOT EXISTS employees_shop_user_idx
  ON public.employees(shop_id, user_id)
  WHERE user_id IS NOT NULL;

-- ── Vérification ──────────────────────────────────────────────────────────
-- 1. La colonne existe et accepte NULL :
--
--   SELECT column_name, data_type, is_nullable
--     FROM information_schema.columns
--    WHERE table_schema = 'public'
--      AND table_name   = 'employees'
--      AND column_name  = 'user_id';
--
--   → attendu : user_id | text | YES
--
-- 2. Aucune ligne existante n'a été touchée :
--
--   SELECT count(*) AS total, count(user_id) AS avec_lien
--     FROM public.employees;
--
--   → attendu : avec_lien = 0 juste après application.
--
-- 3. L'index partiel est en place :
--
--   SELECT indexname FROM pg_indexes
--    WHERE schemaname = 'public' AND tablename = 'employees'
--      AND indexname = 'employees_shop_user_idx';
--
-- 4. APRÈS déploiement, une fiche créée depuis un compte doit porter le lien :
--
--   SELECT id, full_name, has_app_access, user_id
--     FROM public.employees
--    WHERE has_app_access = true
--    ORDER BY created_at DESC
--    LIMIT 5;
--
--   → les fiches ANCIENNES resteront à NULL : ce hotfix ne devine pas
--     rétroactivement à quel compte chacune correspondait. Le rapprochement
--     par le nom reste donc le repli pour elles, et c'est assumé.
