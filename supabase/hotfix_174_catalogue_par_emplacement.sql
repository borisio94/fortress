-- ═════════════════════════════════════════════════════════════════════════════
-- hotfix_174 — Vitrine publique filtrée par emplacement + colmatage d'une fuite.
--
-- ── 1. Catalogue par emplacement ─────────────────────────────────────────────
-- `?location=<stock_location_id>` sur un lien catalogue n'expose que ce qui est
-- réellement en stock DANS CET EMPLACEMENT (dépôt partenaire, boutique). Sans
-- le paramètre, le comportement est strictement inchangé.
--
-- Le lien reste VIVANT : on filtre à la lecture, en base. C'est la différence
-- avec l'ancien partage par emplacement, qui gelait une liste d'`ids` et un
-- snapshot `stock=` dans l'URL — un produit réapprovisionné le lendemain
-- n'apparaissait jamais dans un lien déjà envoyé.
--
-- ── 2. 🔴 FUITE PUBLIQUE REFERMÉE ────────────────────────────────────────────
-- hotfix_101 avait sanitisé le JSONB `variants` des deux RPC publiques :
--     'variants', public._strip_variant_secrets(p.variants)
-- hotfix_124 les a réécrites pour le stock global et a remplacé cette ligne par
--     'variants', h.variants
-- où `h` sort de `_cat_enrich_stock`, qui fait `v || jsonb_build_object(...)`
-- sur l'élément BRUT. Les hotfix 164 et 167 ont recopié la ligne telle quelle.
--
-- Conséquence, en production depuis le 124 : `price_buy`, `supplier`,
-- `supplier_ref`, `stock_ordered` et `stock_physical` sont de nouveau exposés à
-- `anon`. L'UUID de boutique figure dans CHAQUE lien catalogue partagé — il
-- suffit donc d'un lien reçu pour lire les prix d'achat et les fournisseurs.
-- La fuite exacte que le 101 avait fermée, rouverte sans être vue.
--
-- On rétablit le strip sur les DEUX RPC. Aucune clé retirée n'est consommée par
-- la vitrine (elle lit stock_available / stock_qty, tous deux conservés).
--
-- ── Ordre d'application ──────────────────────────────────────────────────────
-- À appliquer AVANT le déploiement de `catalogue.html`. Le nouveau paramètre a
-- un DEFAULT NULL : les liens déjà partagés continuent de fonctionner pendant
-- toute la fenêtre entre l'application et le déploiement.
--
-- Idempotent : DROP IF EXISTS / CREATE OR REPLACE. NOTIFY pgrst en fin.
-- ═════════════════════════════════════════════════════════════════════════════

-- ── 1. Helper : stock par emplacement (ou global si p_location_id IS NULL) ───
--
-- Reprend `_cat_enrich_stock` (hotfix_124) en ajoutant le filtre d'emplacement.
-- L'original est CONSERVÉ : `get_delivery_products` continue de s'en servir, et
-- on ne touche pas à ce qui marche.
--
-- DEUX RÈGLES DISTINCTES, et c'est le cœur du correctif :
--   • p_location_id IS NULL  → comportement du 167 à l'identique, fallback
--     legacy compris (variante jamais synchronisée vers stock_levels → on lit
--     le stock du JSONB, sinon un catalogue entier passerait à zéro).
--   • p_location_id fourni   → AUCUN fallback. Sur un emplacement précis,
--     l'absence de ligne `stock_levels` vaut zéro, point. Garder le fallback
--     ferait apparaître un produit jamais synchronisé DANS TOUS les
--     emplacements, avec son stock global — l'inverse exact du but.
CREATE OR REPLACE FUNCTION public._cat_enrich_stock_at(
  p_variants    jsonb,
  p_owner       text,
  p_location_id text DEFAULT NULL
)
RETURNS TABLE(variants jsonb, total_stock int)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT
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
      -- Σ stock_levels. Le filtre `loc.owner_id = p_owner` vaut aussi
      -- contrôle d'accès : un id d'emplacement appartenant à un autre
      -- propriétaire ne remonte rien (fail-closed, vitrine vide).
      COALESCE((
        SELECT SUM(sl.stock_available)::int
        FROM public.stock_levels sl
        JOIN public.stock_locations loc ON loc.id = sl.location_id
        WHERE sl.variant_id = v->>'id'
          AND loc.is_active
          AND loc.owner_id = p_owner
          AND (p_location_id IS NULL OR sl.location_id = p_location_id)
      ), 0),
      -- Fallback legacy — périmètre GLOBAL uniquement (cf. en-tête).
      CASE WHEN p_location_id IS NULL AND NOT EXISTS (
        SELECT 1 FROM public.stock_levels s2 WHERE s2.variant_id = v->>'id'
      ) THEN COALESCE((v->>'stock_available')::int, (v->>'stock_qty')::int, 0)
        ELSE 0 END
    ) AS g
  ) gs;
$$;

REVOKE ALL ON FUNCTION public._cat_enrich_stock_at(jsonb, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public._cat_enrich_stock_at(jsonb, text, text)
  TO anon, authenticated;

-- ── 2. get_public_catalogue_products — + p_location_id, + strip ─────────────
--
-- Corps repris MOT POUR MOT du hotfix_167 (price_sell_web, track_stock,
-- created_at, description) : deux changements seulement, le helper filtré et le
-- retour du strip. La signature change (3 params) → DROP obligatoire, sinon la
-- surcharge à 2 params subsiste et PostgREST devient ambigu.
DROP FUNCTION IF EXISTS public.get_public_catalogue_products(text, text);
DROP FUNCTION IF EXISTS public.get_public_catalogue_products(text, text, text);

CREATE FUNCTION public.get_public_catalogue_products(
  p_shop_id     text,
  p_category    text DEFAULT NULL,
  p_location_id text DEFAULT NULL
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
    -- Produit avec variantes → total du périmètre ; sans variante → stock_qty.
    'stock_qty',      CASE WHEN jsonb_typeof(p.variants) = 'array'
                            AND jsonb_array_length(p.variants) > 0
                           THEN h.total_stock ELSE p.stock_qty END,
    'track_stock',    COALESCE(p.track_stock, true),
    'image_url',      p.image_url,
    'category_id',    p.category_id,
    'brand',          p.brand,
    'is_visible_web', p.is_visible_web,
    'is_active',      p.is_active,
    'variants',       public._strip_variant_secrets(h.variants),
    'created_at',     p.created_at,
    'description',    p.description
  ) ORDER BY p.name), '[]'::jsonb)
  FROM public.products p
  JOIN public.shops sh ON sh.id::text = p_shop_id AND sh.is_active = true
  CROSS JOIN LATERAL
    public._cat_enrich_stock_at(p.variants, sh.owner_id::text, p_location_id) h
  WHERE p.store_id::text = p_shop_id
    AND p.is_active = true
    AND p.is_visible_web = true
    AND (p_category IS NULL OR p.category_id::text = p_category);
$$;

REVOKE ALL ON FUNCTION public.get_public_catalogue_products(text, text, text)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_catalogue_products(text, text, text)
  TO anon, authenticated;

COMMENT ON FUNCTION public.get_public_catalogue_products(text, text, text) IS
  'Produits actifs + visibles web d''un shop actif. p_location_id NULL = stock '
  'GLOBAL (Σ stock_levels de l''owner) ; p_location_id fourni = stock de CET '
  'emplacement seulement, sans fallback. Variants sanitisées. Voir hotfix_174.';

-- ── 3. get_delivery_products — strip rétabli (signature inchangée) ──────────
--
-- Pas de filtre d'emplacement ici : cette RPC sert les liens à `ids` explicites
-- (partage WhatsApp, deep-link pub), dont le périmètre est déjà figé par la
-- liste d'ids. Seule la sanitisation manquait.
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
    'variants',       public._strip_variant_secrets(h.variants),
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
  'stock GLOBAL + track_stock + price_sell_web + created_at + description. '
  'Variants sanitisées — strip rétabli, voir hotfix_174.';

-- ── 4. Nom public d'un emplacement ─────────────────────────────────────────
--
-- Le bandeau « 📍 <nom> » de la vitrine a besoin du nom, que le visiteur ne
-- peut PAS lire : `stock_locations` est sous RLS (policy exigeant auth.uid()).
-- Cette RPC ne renvoie QUE le nom, et seulement si l'emplacement est actif et
-- appartient au propriétaire du shop demandé — sinon NULL (le bandeau reste
-- masqué, la vitrine ne révèle pas l'existence de l'emplacement).
CREATE OR REPLACE FUNCTION public.get_public_location_label(
  p_shop_id     text,
  p_location_id text
)
RETURNS text
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT loc.name
  FROM public.stock_locations loc
  JOIN public.shops sh
    ON sh.id::text = p_shop_id
   AND sh.is_active = true
   AND loc.owner_id = sh.owner_id::text
  WHERE loc.id = p_location_id
    AND loc.is_active = true;
$$;

REVOKE ALL ON FUNCTION public.get_public_location_label(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_location_label(text, text)
  TO anon, authenticated;

COMMENT ON FUNCTION public.get_public_location_label(text, text) IS
  'Nom d''un emplacement de stock, pour le bandeau de la vitrine filtrée. '
  'NULL si inactif ou appartenant à un autre propriétaire. Voir hotfix_174.';

-- Recharge le cache de schéma PostgREST (sinon PGRST202 quelques minutes).
NOTIFY pgrst, 'reload schema';

-- ── Vérifications (à lancer après application) ─────────────────────────────
--
-- 1. Le lien nu est inchangé (stock global) :
--      SELECT jsonb_array_length(public.get_public_catalogue_products('<shop>'));
--
-- 2. La fuite est refermée — doit renvoyer 0 :
--      SELECT count(*)
--      FROM jsonb_array_elements(
--             public.get_public_catalogue_products('<shop>')) AS prod,
--           jsonb_array_elements(prod->'variants')            AS v
--      WHERE v ? 'price_buy' OR v ? 'supplier' OR v ? 'supplier_ref'
--         OR v ? 'stock_ordered' OR v ? 'stock_physical';
--
-- 3. Le filtre par emplacement réduit bien le périmètre :
--      SELECT jsonb_array_length(
--        public.get_public_catalogue_products('<shop>', NULL, '<location_id>'));
--
-- 4. Un emplacement d'un autre propriétaire ne fuit rien (vitrine vide) :
--      SELECT public.get_public_location_label('<shop>', '<location_etranger>');
--      -- attendu : NULL
