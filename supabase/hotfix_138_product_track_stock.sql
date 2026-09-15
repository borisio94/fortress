-- hotfix_138_product_track_stock.sql
-- ═════════════════════════════════════════════════════════════════════════
-- SUIVI DE STOCK OPTIONNEL PAR PRODUIT.
--
-- Problème résolu : rien ne permettait de dire « cet article n'est pas
-- suivi en stock ». Conséquence pour la restauration, un plat cuisiné
-- (produit à la commande à partir d'ingrédients) voyait soit sa première
-- variante décrémentée à chaque service — stock qui part en négatif —,
-- soit une entrée `stock_decrement_failed` écrite dans le journal
-- d'activité à chaque plat servi.
--
-- Ce drapeau REMPLACE le court-circuit `order_type = 'dine_in'` introduit
-- en PR-3 du module restaurant. Il est plus juste sur deux points :
--   * il porte sur le PRODUIT et non sur le canal de vente → un restaurant
--     peut suivre ses boissons en bouteille tout en ignorant ses plats,
--     ce que le court-circuit par canal interdisait ;
--   * il couvre aussi les commandes à emporter et le catalogue web, qui
--     restaient en `takeaway` et décrémentaient donc le stock à tort.
--
-- Défaut `true` : le comportement historique est conservé pour la totalité
-- du parc existant. Aucune boutique ne voit son suivi de stock changer tant
-- qu'elle n'a pas explicitement décoché l'option sur un produit.
--
-- 100 % idempotent.
-- ═════════════════════════════════════════════════════════════════════════

ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS track_stock BOOLEAN NOT NULL DEFAULT true;

COMMENT ON COLUMN public.products.track_stock IS
  'false = article non suivi en stock (plat cuisiné, service, prestation) : '
  'aucun décrément ni restitution lors des ventes. Défaut true.';

-- Index partiel : les articles non suivis sont une minorité, on ne veut
-- indexer qu'eux (filtres inventaire « masquer les articles non suivis »).
--
-- ATTENTION : la colonne de rattachement boutique de `products` s'appelle
-- `store_id` (et NON `shop_id` comme sur la plupart des autres tables) —
-- cf. `_db.from('products').select().eq('store_id', shopId)` dans
-- `AppDatabase.syncProducts`. Un index sur `shop_id` échouerait ici.
CREATE INDEX IF NOT EXISTS products_untracked_idx
  ON public.products(store_id)
  WHERE track_stock = false;

-- ── Vérification ──────────────────────────────────────────────────────────
--   SELECT column_name, data_type, column_default, is_nullable
--     FROM information_schema.columns
--    WHERE table_name = 'products' AND column_name = 'track_stock';
--
--   -- Doit renvoyer 0 tant qu'aucun produit n'a été décoché :
--   SELECT count(*) FROM public.products WHERE track_stock = false;
--
-- Fin — hotfix_138_product_track_stock.sql
