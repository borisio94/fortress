-- hotfix_141_restaurant_sector.sql
-- ═════════════════════════════════════════════════════════════════════════
-- SECTEUR D'ACTIVITÉ SUR LES PLATS + CATÉGORIE DE PERTE « ÉCART D'INVENTAIRE »
-- (module finances restaurant — Lot 1 de la logique métier).
--
-- 1. `products.activity_id` — rattache un plat à une activité connexe
--    (`restaurant_activities` : Chawarma · Glace · Bar · Pâtisserie…). C'est
--    LE « secteur » du reporting par secteur (Lot 3).
--
--    Choix assumé : PAS d'enum Dart figé (kitchen/shawarma/ice_cream…). Les
--    secteurs sont des données de boutique, créées par l'utilisateur, déjà
--    synchronisées inter-appareils par `restaurant_activities`. Un enum côté
--    Dart aurait figé la liste et n'aurait rien partagé entre appareils.
--
--    Le secteur d'une LIGNE DE VENTE n'est pas stocké : il se déduit du
--    produit à l'affichage. Aucune colonne ajoutée à `orders` — le snapshot
--    figé des commandes ne duplique pas une donnée mutable. Conséquence
--    assumée : déplacer un plat d'activité réétiquette son historique.
--
-- 2. `losses.category` accepte `'ecart_inventaire'` — les pertes issues de la
--    réconciliation d'inventaire (Lot 2) ont leur propre catégorie au lieu de
--    polluer « autre » dans les statistiques.
--
-- PAS DE FK sur `activity_id` (même raison que hotfix_140 / hotfix_137) : en
-- offline-first l'ordre des upserts n'est pas garanti, un plat poussé avant
-- son activité violerait la FK et l'op serait abandonnée après 10 essais.
-- Référence logique, intégrité tenue côté application.
--
-- 100 % idempotent (ré-exécutable sans effet de bord).
-- ═════════════════════════════════════════════════════════════════════════

-- ══════════════════════════════════════════════════════════════════════════
-- 1. PRODUITS — rattachement au secteur (activité connexe).
-- ══════════════════════════════════════════════════════════════════════════
ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS activity_id TEXT;

COMMENT ON COLUMN public.products.activity_id IS
  'Activité connexe de rattachement (restaurant_activities.id) — « secteur » '
  'du reporting restaurant. NULL = plat non rattaché / boutique non '
  'restaurant. Référence logique, sans FK (offline-first).';

-- Index partiel : seuls les plats rattachés sont filtrés par secteur. Les
-- boutiques e-commerce n'écrivent jamais cette colonne → index quasi vide,
-- coût nul pour elles.
CREATE INDEX IF NOT EXISTS products_activity_idx
  ON public.products(activity_id)
  WHERE activity_id IS NOT NULL;

-- ══════════════════════════════════════════════════════════════════════════
-- 2. PERTES — nouvelle catégorie « écart d'inventaire » (réconciliation).
-- ══════════════════════════════════════════════════════════════════════════
-- Le CHECK de hotfix_140 est remplacé (drop puis recreate) : Postgres ne sait
-- pas étendre une contrainte existante. Aucune ligne existante n'est
-- invalidée — la nouvelle liste est un sur-ensemble de l'ancienne.
ALTER TABLE public.losses
  DROP CONSTRAINT IF EXISTS losses_category_check;

ALTER TABLE public.losses
  ADD CONSTRAINT losses_category_check CHECK (category IN (
    'casse','reste_invendu','plat_mal_fait',
    'non_paye','materiel_endommage','ecart_inventaire','autre'));

COMMENT ON COLUMN public.losses.category IS
  'casse · reste_invendu · plat_mal_fait · non_paye · materiel_endommage · '
  'ecart_inventaire (réconciliation d''inventaire, hotfix_141) · autre.';

-- ── Vérification ───────────────────────────────────────────────────────────
--   -- La colonne existe :
--   SELECT column_name, data_type, is_nullable
--     FROM information_schema.columns
--    WHERE table_name = 'products' AND column_name = 'activity_id';
--
--   -- Doit renvoyer 0 tant qu'aucun plat n'a été rattaché :
--   SELECT count(*) FROM public.products WHERE activity_id IS NOT NULL;
--
--   -- Le CHECK accepte la nouvelle catégorie :
--   SELECT pg_get_constraintdef(oid) FROM pg_constraint
--    WHERE conname = 'losses_category_check';
--
-- Fin — hotfix_141_restaurant_sector.sql
