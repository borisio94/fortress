-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_083_block_product_delete_with_stock.sql
--
-- PR-D des 8 garde-fous stock — GF-8 (blocage suppression produit en stock).
--
-- Trigger BEFORE DELETE sur `products` qui refuse la suppression si :
--   1. Une variante du produit a `stock_levels.stock_available > 0` ou
--      `stock_levels.stock_physical > 0` à n'importe quelle location.
--   2. Le produit ou une de ses variantes est référencé dans une commande
--      OUVERTE (status = scheduled ou processing).
--
-- Lève `produit_en_stock` (SQLSTATE P0001) avec un DETAIL JSON parsable
-- côté Flutter pour afficher la même dialog enrichie que côté offline.
--
-- Les variantes sont extraites depuis `products.variants` (JSONB),
-- structure cohérente avec le client (hotfix_013_variant_4_stocks).
-- Les commandes complétées/annulées/refusées/refundées NE sont PAS
-- vérifiées par le trigger — la logique Flutter les bloque déjà côté
-- POS (préservation d'historique), mais le serveur autorise la
-- suppression pour ces cas (cohérent avec la spec GF-8).
--
-- Idempotent : DROP TRIGGER + DROP FUNCTION avant CREATE.
-- ════════════════════════════════════════════════════════════════════════════

DROP TRIGGER  IF EXISTS trg_block_product_delete_with_stock ON public.products;
DROP FUNCTION IF EXISTS public.block_product_delete_with_stock();

CREATE OR REPLACE FUNCTION public.block_product_delete_with_stock()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_variant_ids   text[] := ARRAY[]::text[];
  v_total_avail   integer := 0;
  v_total_phys    integer := 0;
  v_open_sales    integer := 0;
BEGIN
  -- Extraction des variant_ids depuis le JSONB.
  SELECT COALESCE(
    array_agg(DISTINCT (v->>'id'))
      FILTER (WHERE (v->>'id') IS NOT NULL AND length(v->>'id') > 0),
    ARRAY[]::text[]
  )
  INTO v_variant_ids
  FROM jsonb_array_elements(COALESCE(OLD.variants, '[]'::jsonb)) AS v;

  -- 1. Stock résiduel via stock_levels (location-agnostique).
  IF array_length(v_variant_ids, 1) > 0 THEN
    SELECT
      COALESCE(SUM(stock_available), 0),
      COALESCE(SUM(stock_physical),  0)
    INTO v_total_avail, v_total_phys
    FROM public.stock_levels
    WHERE variant_id = ANY(v_variant_ids);
  END IF;

  -- 2. Ventes ouvertes (scheduled / processing) référencant le produit
  --    OU une de ses variantes via items JSONB.
  --    Heuristique : un item référence le produit si son `product_id`
  --    match le produit lui-même OU un de ses variant_ids.
  SELECT count(*)
  INTO v_open_sales
  FROM public.orders o,
       LATERAL jsonb_array_elements(COALESCE(o.items, '[]'::jsonb)) AS it
  WHERE o.status IN ('scheduled', 'processing')
    AND (it->>'product_id' = OLD.id::text
         OR (it->>'product_id' = ANY(v_variant_ids)));

  IF v_total_avail > 0 OR v_total_phys > 0 OR v_open_sales > 0 THEN
    RAISE EXCEPTION 'produit_en_stock'
      USING ERRCODE = 'P0001',
            MESSAGE = format(
              'Suppression refusée : stock=%s/%s, ventes ouvertes=%s',
              v_total_avail, v_total_phys, v_open_sales),
            DETAIL  = jsonb_build_object(
                        'product_id',       OLD.id::text,
                        'product_name',     OLD.name,
                        'total_available',  v_total_avail,
                        'total_physical',   v_total_phys,
                        'open_sales_count', v_open_sales)::text;
  END IF;

  RETURN OLD;
END;
$fn$;

CREATE TRIGGER trg_block_product_delete_with_stock
  BEFORE DELETE ON public.products
  FOR EACH ROW
  EXECUTE FUNCTION public.block_product_delete_with_stock();

-- ────────────────────────────────────────────────────────────────────────
-- Test manuel :
--   1) Créer un produit avec 1 variante stock_available=5 dans stock_levels.
--   2) DELETE FROM products WHERE id = ...; → ERROR 'produit_en_stock'
--      (DETAIL : total_available=5).
--   3) UPDATE stock_levels SET stock_available=0, stock_physical=0
--      WHERE variant_id = ...; puis créer une commande status='scheduled'
--      référencant ce produit.
--   4) DELETE FROM products WHERE id = ...; → ERROR 'produit_en_stock'
--      (DETAIL : open_sales_count=1).
--   5) UPDATE orders SET status='completed' WHERE ... ; puis DELETE → OK.
-- ────────────────────────────────────────────────────────────────────────
