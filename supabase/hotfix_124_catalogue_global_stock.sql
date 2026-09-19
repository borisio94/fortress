-- ═════════════════════════════════════════════════════════════════════════════
-- hotfix_124 — Catalogue public : STOCK GLOBAL (tous emplacements) + created_at
--              + description.
--
-- PROBLÈME : les RPC `get_public_catalogue_products` et `get_delivery_products`
-- exposaient `products.stock_qty` et `products.variants[].stock_*` — c'est-à-dire
-- le stock de la BASE (boutique principale) UNIQUEMENT. Quand un marchand
-- transfère tout son stock vers des dépôts partenaires, sa base passe à 0 → le
-- catalogue public filtre tout (« aucun produit disponible ») alors que le stock
-- existe chez les partenaires.
--
-- CORRECTION : exposer le stock GLOBAL = Σ `stock_levels.stock_available` sur
-- TOUS les emplacements actifs du PROPRIÉTAIRE (base `loc_shop_*` + partenaires).
-- Formule canonique de l'app (cf. lib/features/inventaire/domain/stock_at_location
-- .dart + dashboard_providers.dart vue « Globale ») :
--   global(variante) = Σ stock_levels(variant_id, locations actives de l'owner)
--   → on NE rajoute PAS products.variants[].stock_qty : la base est DÉJÀ une
--     ligne stock_levels à `loc_shop_<shopId>` (sync `_syncShopStockLevelsFrom
--     Product` à chaque saveProduct). Sinon double comptage.
--   → fallback : si la variante n'a AUCUNE ligne stock_levels (legacy non
--     migrée), on retombe sur son stock JSONB base.
--
-- BONUS : on expose aussi `created_at` (badge « Nouveau » côté catalogue) et
-- `description` (fiche détail).
--
-- NB FULFILLMENT : router la commande vers le bon emplacement quand la base est
-- vide reste un problème séparé (à traiter plus tard) — ici on ne corrige que
-- l'AFFICHAGE / la disponibilité.
--
-- Idempotent. À appliquer dans Supabase → SQL editor.
-- ═════════════════════════════════════════════════════════════════════════════

-- ── 1. Helper : enrichit le JSONB `variants` avec le stock GLOBAL par variante
--       et renvoie le total global. SECURITY DEFINER → bypass RLS sur
--       stock_levels / stock_locations.
CREATE OR REPLACE FUNCTION public._cat_enrich_stock(
  p_variants jsonb,
  p_owner    text
)
RETURNS TABLE(variants jsonb, total_stock int)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT
    -- variants reconstruites : stock_available + stock_qty = stock global
    COALESCE(jsonb_agg(
      v || jsonb_build_object('stock_available', g, 'stock_qty', g)
    ), p_variants),
    COALESCE(SUM(g), 0)::int
  FROM jsonb_array_elements(
    CASE WHEN jsonb_typeof(p_variants) = 'array'
         THEN p_variants ELSE '[]'::jsonb END
  ) v
  CROSS JOIN LATERAL (
    SELECT GREATEST(
      -- Σ stock_levels sur les emplacements actifs du propriétaire (base +
      -- partenaires). La base loc_shop_* est incluse (type='shop', owner).
      COALESCE((
        SELECT SUM(sl.stock_available)::int
        FROM public.stock_levels sl
        JOIN public.stock_locations loc ON loc.id = sl.location_id
        WHERE sl.variant_id = v->>'id'
          AND loc.is_active
          AND loc.owner_id = p_owner
      ), 0),
      -- Fallback legacy : variante jamais synchronisée vers stock_levels →
      -- stock JSONB base.
      CASE WHEN NOT EXISTS (
        SELECT 1 FROM public.stock_levels s2 WHERE s2.variant_id = v->>'id'
      ) THEN COALESCE((v->>'stock_available')::int, (v->>'stock_qty')::int, 0)
        ELSE 0 END
    ) AS g
  ) gs;
$$;

REVOKE ALL ON FUNCTION public._cat_enrich_stock(jsonb, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public._cat_enrich_stock(jsonb, text)
  TO anon, authenticated;

-- ── 2. get_public_catalogue_products — stock GLOBAL + created_at + description.
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
  'stock_levels tous emplacements de l''owner) + created_at + description. '
  'Voir hotfix_124 (corrige le catalogue vide quand la base a transféré son '
  'stock aux partenaires).';

-- ── 3. get_delivery_products — idem (stock GLOBAL) pour les liens ids/produit.
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
  'avec STOCK GLOBAL + created_at + description. Voir hotfix_124.';

-- Recharge le cache de schéma PostgREST (sinon PGRST202 quelques minutes).
NOTIFY pgrst, 'reload schema';
