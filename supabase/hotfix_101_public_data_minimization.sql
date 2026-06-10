-- ═════════════════════════════════════════════════════════════════════════════
-- hotfix_101 — Minimisation des données exposées par les flux PUBLICS.
--
-- 🔴 Failles corrigées (audit prod-readiness, test 1.3 « RPC publiques ») :
--
--   1. Policy RLS anon `products_anon_read_visible_web` (hotfix_045) :
--      RLS filtre les LIGNES, pas les COLONNES. Un visiteur anonyme muni de
--      l'UUID de boutique (présent dans CHAQUE lien catalogue partagé) pouvait
--      lire la ligne products entière en select=* :
--        GET /rest/v1/products?select=price_buy,customs_fee,tax_rate,variants&store_id=eq.<id>
--      → fuite publique des PRIX D'ACHAT, MARGES, TAXES, DOUANES + le JSONB
--        variants (price_buy / supplier / supplier_ref par variante).
--      La page catalogue n'utilise PLUS cette policy : elle est 100% migrée
--      sur les RPC SECURITY DEFINER get_public_catalogue_products /
--      get_delivery_products (hotfix_094/097). La policy est donc du code mort
--      MAIS reste exploitable via un appel PostgREST direct → on la SUPPRIME.
--
--   2. Policy RLS anon `shops_anon_read_active` (hotfix_045) : idem, exposait
--      toute la ligne shops (owner_id, email, etc.) en anon. La page utilise
--      désormais get_public_shop_info (hotfix_095) → on la SUPPRIME.
--
--   3. Les RPC get_public_catalogue_products / get_delivery_products
--      renvoyaient le JSONB `variants` BRUT → fuite price_buy/supplier même
--      par la RPC. On filtre désormais les clés sensibles de chaque variante.
--
--   4. get_tracked_order (hotfix_057) renvoyait `items` BRUT ; or chaque item
--      de commande embarque `price_buy` (cf. _saleToMap). Le client (ou
--      quiconque a l'UUID de commande) voyait le coût d'achat → on le retire.
--
-- Vérifié : l'UI catalogue/suivi NE consomme aucune des clés retirées
-- (price_buy, supplier, supplier_ref, tax/customs, stock interne).
--
-- 100% idempotent. NOTIFY pgrst en fin pour recharger le cache PostgREST.
-- ═════════════════════════════════════════════════════════════════════════════

-- ── 1 & 2. Suppression des policies anon trop larges ───────────────────────
DROP POLICY IF EXISTS "products_anon_read_visible_web" ON public.products;
DROP POLICY IF EXISTS "shops_anon_read_active"          ON public.shops;

-- ── Helpers de minimisation (blacklist : on RETIRE les clés sensibles, on
--    garde tout le reste → aucun risque de casser un champ d'affichage) ─────
CREATE OR REPLACE FUNCTION public._strip_variant_secrets(p_variants jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT COALESCE(
    jsonb_agg(
      elem - 'price_buy' - 'supplier' - 'supplier_ref'
           - 'stock_ordered' - 'stock_physical'
    ),
    '[]'::jsonb)
  FROM jsonb_array_elements(COALESCE(p_variants, '[]'::jsonb)) AS elem;
$$;

CREATE OR REPLACE FUNCTION public._strip_item_secrets(p_items jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT COALESCE(
    jsonb_agg(elem - 'price_buy'),
    '[]'::jsonb)
  FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb)) AS elem;
$$;

-- ── 3a. get_public_catalogue_products : variants sanitisées ────────────────
DROP FUNCTION IF EXISTS public.get_public_catalogue_products(text, text);
CREATE FUNCTION public.get_public_catalogue_products(
  p_shop_id  text,
  p_category text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',             p.id,
    'name',           p.name,
    'sku',            p.sku,
    'price_sell_pos', p.price_sell_pos,
    'stock_qty',      p.stock_qty,
    'image_url',      p.image_url,
    'category_id',    p.category_id,
    'brand',          p.brand,
    'is_visible_web', p.is_visible_web,
    'is_active',      p.is_active,
    'variants',       public._strip_variant_secrets(p.variants)
  ) ORDER BY p.name), '[]'::jsonb)
  FROM public.products p
  WHERE p.store_id::text = p_shop_id
    AND p.is_active = true
    AND p.is_visible_web = true
    AND (p_category IS NULL OR p.category_id::text = p_category)
    AND EXISTS (
      SELECT 1 FROM public.shops s
      WHERE s.id::text = p_shop_id AND s.is_active = true
    );
$$;
REVOKE ALL ON FUNCTION public.get_public_catalogue_products(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_catalogue_products(text, text)
  TO anon, authenticated;

-- ── 3b. get_delivery_products : variants sanitisées ────────────────────────
DROP FUNCTION IF EXISTS public.get_delivery_products(text, text[]);
CREATE FUNCTION public.get_delivery_products(
  p_shop_id     text,
  p_product_ids text[]
) RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',             p.id,
    'name',           p.name,
    'sku',            p.sku,
    'price_sell_pos', p.price_sell_pos,
    'stock_qty',      p.stock_qty,
    'image_url',      p.image_url,
    'category_id',    p.category_id,
    'brand',          p.brand,
    'is_visible_web', p.is_visible_web,
    'is_active',      p.is_active,
    'variants',       public._strip_variant_secrets(p.variants)
  )), '[]'::jsonb)
  FROM public.products p
  WHERE p.store_id = p_shop_id::text
    AND p.is_active = true
    AND (
      p.id::text = ANY(p_product_ids)
      OR EXISTS (
        SELECT 1
        FROM jsonb_array_elements(p.variants) v
        WHERE v->>'id' = ANY(p_product_ids)
      )
    );
$$;
REVOKE ALL ON FUNCTION public.get_delivery_products(text, text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_delivery_products(text, text[])
  TO anon, authenticated;

-- ── 4. get_tracked_order : items sanitisés (retrait price_buy) ─────────────
DROP FUNCTION IF EXISTS public.get_tracked_order(text);
CREATE OR REPLACE FUNCTION public.get_tracked_order(p_order_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_row jsonb;
BEGIN
  IF p_order_id IS NULL OR length(trim(p_order_id)) = 0 THEN
    RAISE EXCEPTION 'order_id_required' USING ERRCODE = '22023';
  END IF;

  SELECT jsonb_build_object(
    'id',              o.id::text,
    'shop_id',         o.shop_id,
    'status',          o.status,
    'items',           public._strip_item_secrets(o.items),
    'discount_amount', o.discount_amount,
    'tax_rate',        o.tax_rate,
    'client_name',     o.client_name,
    'client_phone',    o.client_phone,
    'notes',           o.notes,
    'scheduled_at',    o.scheduled_at,
    'created_at',      o.created_at,
    'shop_name',       s.name,
    'shop_phone',      s.phone
  )
    INTO v_row
    FROM orders o
    JOIN shops  s ON s.id::text = o.shop_id
   WHERE o.id::text = p_order_id
     AND s.is_active = true;

  IF v_row IS NULL THEN
    RAISE EXCEPTION 'order_not_found' USING ERRCODE = '42P01';
  END IF;

  RETURN v_row;
END;
$fn$;
REVOKE ALL ON FUNCTION public.get_tracked_order(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_tracked_order(text) TO anon, authenticated;

-- ── Recharge du cache PostgREST ────────────────────────────────────────────
NOTIFY pgrst, 'reload schema';
