-- ═════════════════════════════════════════════════════════════════════════════
-- hotfix_131 — RPC SECURITY DEFINER `get_public_promo_campaign`.
--
-- Contexte : le lien public de campagne `/promo/:shopId/:campaignId` était
-- servi par l'app Flutter (PromoShowcasePage, ~15 Mo) qui ne faisait QUE
-- incrémenter view_count puis rediriger vers le catalogue filtré
-- (/catalogue/:shopId?ids=...). On remplace cette page par une mini-page
-- statique `promo.html` (rewrite Firebase), comme catalogue.html / track.html.
--
-- Pour préserver l'analytics (view_count) ET récupérer les produits de la
-- campagne sans exposer toute la table `promo_campaigns` à l'anon, cette RPC :
--   • incrémente atomiquement view_count,
--   • retourne UNIQUEMENT { shop_id, product_ids[] } (données minimales),
--   • fonctionne quel que soit le rôle de l'appelant (anon inclus).
--
-- Aligné sur les autres RPC publiques (get_public_catalogue_products
-- hotfix_097, get_public_shop_info hotfix_095, increment_promo_view
-- hotfix_068). Retourne NULL si la campagne est introuvable → la page
-- promo.html retombe alors gracieusement sur le catalogue complet.
-- ═════════════════════════════════════════════════════════════════════════════

BEGIN;

DROP FUNCTION IF EXISTS public.get_public_promo_campaign(uuid);

CREATE FUNCTION public.get_public_promo_campaign(p_campaign_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_shop_id  text;
  v_products jsonb;
  v_ids      jsonb;
BEGIN
  -- Incrément atomique de la vue + récupération des données minimales.
  UPDATE public.promo_campaigns
     SET view_count = view_count + 1
   WHERE id = p_campaign_id
  RETURNING shop_id::text, products INTO v_shop_id, v_products;

  -- Campagne introuvable → NULL (la page web retombe sur le catalogue).
  IF v_shop_id IS NULL THEN
    RETURN NULL;
  END IF;

  -- Extrait la liste des product_id du snapshot JSONB `products`.
  SELECT COALESCE(jsonb_agg(elem->>'product_id'), '[]'::jsonb)
    INTO v_ids
    FROM jsonb_array_elements(COALESCE(v_products, '[]'::jsonb)) AS elem
   WHERE COALESCE(elem->>'product_id', '') <> '';

  RETURN jsonb_build_object(
    'shop_id',     v_shop_id,
    'product_ids', v_ids
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_public_promo_campaign(uuid)
  TO anon, authenticated;

COMMIT;
