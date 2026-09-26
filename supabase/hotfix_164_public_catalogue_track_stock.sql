-- hotfix_164_public_catalogue_track_stock.sql
-- ═════════════════════════════════════════════════════════════════════════
-- VENDRE EN LIGNE CE QUI N'EST PAS EN RAYON — `track_stock` au catalogue.
--
-- Une boutique commercialise deux natures d'articles :
--   * ceux qu'elle stocke — le compteur fait foi, à 0 c'est une rupture ;
--   * ceux qu'elle vend SANS stock — service, prestation, article importé
--     ou fabriqué à la demande. Il n'y a rien à compter : l'article est
--     disponible en permanence.
--
-- Le drapeau existe déjà sur le produit (`products.track_stock`,
-- hotfix_138) mais les RPC publiques ne l'exposaient pas. Le catalogue en
-- ligne ne pouvait donc que constater `stock_qty = 0` et filtrait l'article
-- (`catalogue.html` : « ne jamais exposer une rupture »). Résultat : un
-- article sur commande était invisible pour le client — invendable en ligne
-- alors que c'est précisément ce qu'on voulait vendre.
--
-- Ce hotfix ne change AUCUNE règle de visibilité côté serveur : il ajoute
-- une clé au JSON pour que le client sache distinguer « rupture » de « sans
-- stock par nature ». Les produits restent filtrés par `is_active` et
-- `is_visible_web` comme avant.
--
-- Reprend à l'identique le corps de hotfix_124 (stock GLOBAL via
-- `_cat_enrich_stock`) — seule la clé `track_stock` est ajoutée.
--
-- 100 % idempotent (ré-exécutable sans effet de bord).
-- ═════════════════════════════════════════════════════════════════════════

-- ── 1. get_public_catalogue_products ───────────────────────────────────
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
    -- Produit avec variantes → total global ; sans variante → stock_qty base.
    'stock_qty',      CASE WHEN jsonb_typeof(p.variants) = 'array'
                            AND jsonb_array_length(p.variants) > 0
                           THEN h.total_stock ELSE p.stock_qty END,
    -- NOUVEAU : false = article sur commande, jamais en rupture.
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
  'stock_levels tous emplacements de l''owner) + track_stock + created_at + '
  'description. Voir hotfix_164 (les articles sur commande, track_stock = '
  'false, ne sont plus filtrés comme des ruptures).';

-- ── 2. get_delivery_products ───────────────────────────────────────────
DROP FUNCTION IF EXISTS public.get_delivery_products(text, text[]);

CREATE FUNCTION public.get_delivery_products(
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
  'avec STOCK GLOBAL + track_stock + created_at + description. '
  'Voir hotfix_164.';

-- Recharge le cache de schéma PostgREST (sinon PGRST202 quelques minutes).
NOTIFY pgrst, 'reload schema';
