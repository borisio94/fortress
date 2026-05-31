-- ═════════════════════════════════════════════════════════════════════════════
-- hotfix_097 — RPC SECURITY DEFINER `get_public_catalogue_products`.
--
-- Contexte : la branche « catalogue complet » de CataloguePage (partage
-- catalogue depuis l'inventaire en mode `all` ou `category`, sans ids
-- explicites) lit `products` directement :
--   db.from('products').select(...).eq('store_id', ...).eq('is_active', true)
--                       .eq('is_visible_web', true)
--
-- Cette lecture est régie par les policies RLS de `products` :
--   • `products_anon_read_visible_web`  (TO anon)         → public
--   • `products_select`                 (TO authenticated) → _is_shop_member
--
-- Conséquence (même schéma que hotfix_095 sur `shops`) : un utilisateur
-- AUTHENTIFIÉ NON-MEMBRE du shop ne matche aucune policy SELECT → la
-- requête retourne 0 row → CataloguePage affiche « aucun produit
-- disponible pour le moment ». Reproductible sur mobile quand le marchand
-- ouvre son propre lien partagé alors qu'il a une session Supabase
-- persistée (browser web même origin que l'app).
--
-- Solution : un RPC SECURITY DEFINER aligné avec hotfix_094
-- (`get_delivery_products`) et hotfix_095 (`get_public_shop_info`). Il
-- retourne les produits actifs + visibles web d'un shop actif, avec
-- filtre optionnel par catégorie, quel que soit le rôle de l'appelant.
--
-- Modèle de sécurité : l'accès est protégé par la connaissance de l'UUID
-- du shop (mêmes garanties que les liens publics catalogue existants).
-- Filtre strict `is_visible_web = true` ici (contrairement à
-- `get_delivery_products` qui bypasse `is_visible_web` quand un set
-- d'ids explicite est fourni — consentement implicite).
--
-- Idempotent : DROP IF EXISTS avant CREATE.
-- ═════════════════════════════════════════════════════════════════════════════

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
  -- Retour en jsonb (cf. hotfix_094) pour éviter ERROR 42804 si une
  -- colonne diverge en type. Vérifie aussi que le shop est actif.
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
    'variants',       p.variants
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

REVOKE ALL ON FUNCTION public.get_public_catalogue_products(text, text)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_catalogue_products(text, text)
  TO anon, authenticated;

COMMENT ON FUNCTION public.get_public_catalogue_products(text, text) IS
  'Retourne les produits actifs et visibles web d''un shop actif pour '
  'la page catalogue publique (partage catalogue complet ou par '
  'catégorie). Bypass RLS pour servir aussi les utilisateurs '
  'authentifiés non-membres du shop. Voir hotfix_097.';

-- Force PostgREST à recharger son schema cache. Sans ça, le RPC peut
-- rester invisible (PGRST202 « Could not find the function ») pendant
-- quelques minutes après création.
NOTIFY pgrst, 'reload schema';
