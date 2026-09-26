-- hotfix_167_public_catalogue_price_web.sql
-- ═════════════════════════════════════════════════════════════════════════
-- PRIX WEB AU CATALOGUE — `price_sell_web` exposé par les RPC publiques.
--
-- Le commerçant saisit un prix de vente web dans la fiche produit (champ
-- affiché quand « visible web » est actif), mais les RPC publiques ne
-- renvoyaient que `price_sell_pos` au niveau produit : la vitrine
-- (`catalogue.html`) ne pouvait pas l'honorer.
--
-- Côté variantes, la clé était déjà présente (JSON complet renvoyé par
-- `_cat_enrich_stock`). Ce hotfix l'ajoute au niveau PRODUIT, pour couvrir
-- les produits sans variante.
--
-- Aucune règle de visibilité ne change : une clé de plus dans le JSON. Le
-- prix web n'est PAS une donnée sensible (c'est le prix affiché au client),
-- contrairement au prix d'achat qui reste exclu (cf. hotfix_101).
--
-- Reprend à l'identique le corps de hotfix_164 — seule `price_sell_web` est
-- ajoutée. Signature et type de retour inchangés → CREATE OR REPLACE suffit.
--
-- 100 % idempotent (ré-exécutable sans effet de bord).
-- ═════════════════════════════════════════════════════════════════════════

-- ── 1. get_public_catalogue_products ───────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_public_catalogue_products(
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
    -- NOUVEAU : prix web, prime sur le prix POS côté vitrine quand > 0.
    'price_sell_web', p.price_sell_web,
    -- Produit avec variantes → total global ; sans variante → stock_qty base.
    'stock_qty',      CASE WHEN jsonb_typeof(p.variants) = 'array'
                            AND jsonb_array_length(p.variants) > 0
                           THEN h.total_stock ELSE p.stock_qty END,
    'track_stock',    COALESCE(p.track_stock, true),
    'image_url',      p.image_url,
    'category_id',    p.category_id,
    'brand',          p.brand,
    'is_visible_web', p.is_visible_web,
    'is_active',      p.is_active,
    'variants',       h.variants,
    'created_at',     p.created_at,
    'description',    p.description
  ) ORDER BY p.name), '[]'::jsonb)
  FROM public.products p
  JOIN public.shops sh ON sh.id::text = p_shop_id AND sh.is_active = true
  CROSS JOIN LATERAL public._cat_enrich_stock(p.variants, sh.owner_id::text) h
  WHERE p.store_id::text = p_shop_id
    AND p.is_active = true
    AND p.is_visible_web = true
    AND (p_category IS NULL OR p.category_id::text = p_category);
$$;

REVOKE ALL ON FUNCTION public.get_public_catalogue_products(text, text)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_catalogue_products(text, text)
  TO anon, authenticated;

COMMENT ON FUNCTION public.get_public_catalogue_products(text, text) IS
  'Produits actifs + visibles web d''un shop actif, avec STOCK GLOBAL (Σ '
  'stock_levels tous emplacements de l''owner) + track_stock + price_sell_web '
  '+ created_at + description. Voir hotfix_167.';

-- ── 2. get_delivery_products ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_delivery_products(
  p_shop_id     text,
  p_product_ids text[]
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
    'price_sell_web', p.price_sell_web,
    'stock_qty',      CASE WHEN jsonb_typeof(p.variants) = 'array'
                            AND jsonb_array_length(p.variants) > 0
                           THEN h.total_stock ELSE p.stock_qty END,
    'track_stock',    COALESCE(p.track_stock, true),
    'image_url',      p.image_url,
    'category_id',    p.category_id,
    'brand',          p.brand,
    'is_visible_web', p.is_visible_web,
    'is_active',      p.is_active,
    'variants',       h.variants,
    'created_at',     p.created_at,
    'description',    p.description
  )), '[]'::jsonb)
  FROM public.products p
  JOIN public.shops sh ON sh.id::text = p_shop_id
  CROSS JOIN LATERAL public._cat_enrich_stock(p.variants, sh.owner_id::text) h
  WHERE p.store_id::text = p_shop_id
    AND p.is_active = true
    AND (
      p.id::text = ANY(p_product_ids)
      OR EXISTS (
        SELECT 1 FROM jsonb_array_elements(p.variants) v
        WHERE v->>'id' = ANY(p_product_ids)
      )
    );
$$;

REVOKE ALL ON FUNCTION public.get_delivery_products(text, text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_delivery_products(text, text[])
  TO anon, authenticated;

COMMENT ON FUNCTION public.get_delivery_products(text, text[]) IS
  'Produits par ids explicites (lien partagé / pub), bypass is_visible_web, '
  'avec STOCK GLOBAL + track_stock + price_sell_web + created_at + '
  'description. Voir hotfix_167.';

-- Recharge le cache de schéma PostgREST.
NOTIFY pgrst, 'reload schema';

-- ── Vérification (à lancer après application) ─────────────────────────
--   SELECT public.get_public_catalogue_products('<shop_id>') -> 0 -> 'price_sell_web';
