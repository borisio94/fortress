-- ═════════════════════════════════════════════════════════════════════════════
-- hotfix_094 — RPC SECURITY DEFINER `get_delivery_products`.
--
-- Contexte : la mini-vitrine catalogue (CataloguePage) accédée via un lien
-- partagé (livraison ou partage manuel) plante côté livreur anonyme parce
-- que la policy publique `products_anon_read_visible_web` exige
-- `is_visible_web = true`. Ce flag est censé être mis à jour côté client
-- avant l'envoi du lien, mais :
--   • la race entre l'UPDATE Supabase et le clic du livreur n'est pas
--     fiable (queue offline, latence réseau, ancien lien en cache)
--   • dépendre du flag is_visible_web pour un partage CIBLÉ (livraison à
--     UN partenaire) est mal calibré — l'owner a déjà décidé en générant
--     le lien que ces produits doivent être consultables, pas besoin
--     d'une étape supplémentaire de publication implicite.
--
-- Solution : un RPC SECURITY DEFINER qui retourne les produits demandés
-- par leur id explicite, sans passer par RLS. Vérifie quand même :
--   • produit appartient bien à `store_id = p_shop_id` (pas de cross-shop)
--   • produit `is_active = true` (pas d'archivé)
-- Pas de filtre `is_visible_web` ici — c'est la valeur ajoutée du RPC.
--
-- Modèle de sécurité : l'accès est protégé par la connaissance des UUIDs
-- (shop_id + product_ids), mêmes garanties que les liens publics
-- catalogue existants. Anonyme peut appeler le RPC mais doit fournir
-- exactement les ids attendus → pas d'énumération possible.
-- ═════════════════════════════════════════════════════════════════════════════

-- Notes :
-- 1. Les champs promo (`promo_enabled`, `promo_price`, `promo_start`,
--    `promo_end`) ne sont PAS des colonnes de `products` — ils sont stockés
--    DANS chaque entrée du JSONB `variants` (cf. catalogue_page._effectivePrice).
-- 2. Le retour est en JSONB construit côté PG plutôt qu'en TABLE typé :
--    on évite ainsi les ERROR 42804 « return type mismatch » au cas où
--    les colonnes `id`, `category_id`, etc. seraient des `uuid` ou des
--    `varchar` au lieu de `text`. PG sérialise tout en JSON automatiquement,
--    Dart récupère un List<Map<String, dynamic>> côté supabase-flutter.
DROP FUNCTION IF EXISTS public.get_delivery_products(text, text[]);

-- Le WHERE accepte AUSSI les IDs de variante (filet de sécurité Couche 2,
-- ticket 2026-05-27). Le `SaleItem.productId` peut stocker en réalité un
-- `var_<timestamp>_<index>` quand l'item est une variante — sans cette
-- branche le RPC ne matchait rien et la page restait vide. La Couche 1
-- côté Dart résout déjà variantId → parentId dans l'URL, mais cette
-- garde-fou couvre les vieilles commandes / autres call sites.
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
    'id',             id,
    'name',           name,
    'sku',            sku,
    'price_sell_pos', price_sell_pos,
    'stock_qty',      stock_qty,
    'image_url',      image_url,
    'category_id',    category_id,
    'brand',          brand,
    'is_visible_web', is_visible_web,
    'is_active',      is_active,
    'variants',       variants
  )), '[]'::jsonb)
  FROM public.products p
  WHERE store_id = p_shop_id::text
    AND is_active = true
    AND (
      -- Match direct sur products.id (cas normal).
      id::text = ANY(p_product_ids)
      -- OU : un des IDs demandés se trouve dans p.variants[].id (variante).
      OR EXISTS (
        SELECT 1
        FROM jsonb_array_elements(p.variants) v
        WHERE v->>'id' = ANY(p_product_ids)
      )
    );
$$;

-- Grant explicite (anon + authenticated). Le SECURITY DEFINER déjà
-- bypasse RLS, donc le grant suffit pour autoriser l'appel.
REVOKE ALL ON FUNCTION public.get_delivery_products(text, text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_delivery_products(text, text[])
  TO anon, authenticated;

COMMENT ON FUNCTION public.get_delivery_products(text, text[]) IS
  'Retourne les produits demandés explicitement par leur id pour la '
  'mini-vitrine catalogue (lien partagé, contexte livraison). Bypass RLS '
  'is_visible_web — l''owner décide en générant le lien. Voir hotfix_094.';
