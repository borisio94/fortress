-- hotfix_180_restaurant_tables_soft_delete.sql
-- ═════════════════════════════════════════════════════════════════════════
-- PLAN DE SALLE — la suppression d'une table devient RÉVERSIBLE.
--
-- Supprimer une table effaçait la ligne : `box.delete` en local, `DELETE` en
-- base, sans tombstone et sans motif. Une table supprimée par erreur ne se
-- récupérait pas — alors qu'elle est référencée par `orders.table_id` sur tout
-- l'historique des commandes qu'elle a servies (référence logique, sans FK,
-- cf. hotfix_137).
--
-- Elle est désormais MARQUÉE supprimée. La ligne survit, l'app la filtre à la
-- lecture. Même mécanique que `products.deleted_at` (hotfix_085).
--
-- ── DEUX CHANGEMENTS, PAS UN ────────────────────────────────────────────────
--
-- L'index unique `(shop_id, number)` doit devenir PARTIEL, sans quoi la
-- fonctionnalité serait cassée le jour même : `RestaurantTableService
-- .nextNumber` comble les trous en ne regardant que les tables vivantes. Après
-- suppression de T2, il proposerait donc « 2 » — et l'insertion violerait
-- l'index, puisque la T2 supprimée occuperait encore ce numéro.
--
-- Un numéro libéré par une suppression redevient donc attribuable, exactement
-- comme avant ce hotfix. C'est l'ancien comportement qui est préservé, pas un
-- nouveau qui est introduit.
--
-- ⚠ CE FICHIER S'APPLIQUE AVANT LE DÉPLOIEMENT DU CLIENT.
-- `RestaurantTable.toMap` envoie `deleted_at` : sans la colonne, Supabase
-- rejette l'upsert (PGRST204) et la suppression ne quitterait jamais
-- l'appareil qui l'a faite.
--
-- ADD COLUMN sans défaut : métadonnée seule, aucune réécriture de table.
-- 100 % idempotent.
-- ═════════════════════════════════════════════════════════════════════════

ALTER TABLE public.restaurant_tables
  ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

-- Index unique PARTIEL : deux tables peuvent porter le même numéro si l'une
-- d'elles est supprimée. `DROP` puis `CREATE` plutôt qu'un `CREATE OR REPLACE`,
-- qui n'existe pas pour les index — et l'ancien index, total, refuserait de
-- coexister avec le nouveau sur les mêmes colonnes.
DROP INDEX IF EXISTS public.restaurant_tables_shop_number_uidx;
CREATE UNIQUE INDEX IF NOT EXISTS restaurant_tables_shop_number_uidx
  ON public.restaurant_tables(shop_id, number)
  WHERE deleted_at IS NULL;

-- Lecture courante du plan de salle : les tables vivantes d'une boutique.
-- Sans cet index, chaque ouverture de l'écran filtre `deleted_at IS NULL` sur
-- l'ensemble des lignes de la boutique, supprimées comprises.
CREATE INDEX IF NOT EXISTS restaurant_tables_shop_alive_idx
  ON public.restaurant_tables(shop_id)
  WHERE deleted_at IS NULL;

-- ── Vérification ──────────────────────────────────────────────────────────
-- Doit renvoyer la colonne, l'index partiel, et 0 doublon de numéro vivant.
--
--   SELECT column_name FROM information_schema.columns
--    WHERE table_schema='public' AND table_name='restaurant_tables'
--      AND column_name='deleted_at';
--
--   SELECT indexname, indexdef FROM pg_indexes
--    WHERE schemaname='public' AND tablename='restaurant_tables';
--
--   SELECT shop_id, number, count(*) FROM public.restaurant_tables
--    WHERE deleted_at IS NULL GROUP BY 1,2 HAVING count(*) > 1;
