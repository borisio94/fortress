-- ═════════════════════════════════════════════════════════════════════════════
-- hotfix_096 — get_tracked_order : fallback image depuis products
--
-- Contexte : pour les commandes créées avant hotfix forward (sale_local_
-- datasource + place_public_order), `orders.items[].image_url` est null
-- ou absent. La page /track/:orderId affichait alors un placeholder gris
-- même si le produit/variante avait bien une image.
--
-- Solution : enrichir chaque item retourné par `get_tracked_order` avec
-- l'image_url du produit (ou de la variante quand variant_id matche un
-- entry du JSONB products.variants). Fallback chain :
--   1. items[i].image_url (snapshot original — préservé si présent)
--   2. products.variants[?].image_url (où ?.id = items[i].variant_id
--      OU ?.id = items[i].product_id, cf. hotfix_094 qui montre que
--      products.id peut en réalité être un variantId pour vieux records)
--   3. products.image_url (image principale du produit parent)
--   4. null (placeholder côté client)
--
-- N'écrit RIEN en base — pure transformation à la lecture. Les nouvelles
-- commandes (créées après le patch sale_local_datasource) auront leur
-- image_url stocké directement dans items[i].image_url, donc la chaîne
-- s'arrêtera à l'étape 1.
--
-- Idempotent : DROP IF EXISTS avant CREATE.
-- ═════════════════════════════════════════════════════════════════════════════

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
    -- Items enrichis : chaque item reçoit un image_url s'il n'en a pas
    -- déjà, via lookup products (parent ou variante).
    'items',           COALESCE((
      SELECT jsonb_agg(
        CASE
          WHEN COALESCE(item->>'image_url', '') <> ''
            THEN item
          ELSE item || jsonb_build_object(
            'image_url',
            (
              -- Cherche d'abord une variante dont id matche
              -- variant_id ou product_id de l'item ; sinon retombe
              -- sur products.image_url. NULL final = pas d'image
              -- trouvée → client affichera le placeholder.
              SELECT COALESCE(
                (SELECT v->>'image_url'
                   FROM jsonb_array_elements(p.variants) v
                  WHERE v->>'id' = item->>'variant_id'
                     OR v->>'id' = item->>'product_id'
                  LIMIT 1),
                p.image_url
              )
              FROM products p
              WHERE p.store_id::text = o.shop_id::text
                AND (
                  p.id::text = item->>'product_id'
                  OR EXISTS (
                    SELECT 1 FROM jsonb_array_elements(p.variants) v
                    WHERE v->>'id' = item->>'product_id'
                       OR v->>'id' = item->>'variant_id'
                  )
                )
              LIMIT 1
            )
          )
        END
      )
      FROM jsonb_array_elements(o.items) item
    ), o.items),
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

COMMENT ON FUNCTION public.get_tracked_order(text) IS
  'Retourne une commande pour la page publique /track/:id avec '
  'fallback image_url depuis products.variants[?].image_url ou '
  'products.image_url quand items[i].image_url est absent. Voir '
  'hotfix_057 + hotfix_096.';
