-- ═════════════════════════════════════════════════════════════════════════════
-- hotfix_122 — Expose `logo_url` dans get_public_shop_info (vitrine catalogue).
--
-- Contexte : la page publique `/catalogue/:shopId` affichait le logo Fortress
-- générique en en-tête car le RPC `get_public_shop_info` (hotfix_095) ne
-- renvoyait que id/name/phone/whatsapp_phone. Pour qu'un visiteur Facebook voie
-- le LOGO DE LA BOUTIQUE (et pour l'aperçu Open Graph côté Cloud Function), on
-- ajoute `logo_url` au retour.
--
-- `shops.logo_url` (hotfix_087) est une URL publique (bucket `shop_logos`
-- public) → aucune donnée sensible exposée. Le client Flutter lit déjà
-- `shopRow['logo_url']` (null-safe) ; tant que ce hotfix n'est pas appliqué,
-- il retombe sur le logo Fortress.
--
-- Idempotent : CREATE OR REPLACE (même signature). NOTIFY pgrst en fin.
-- ═════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.get_public_shop_info(p_shop_id text)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'id',             id,
    'name',           name,
    'phone',          phone,
    'whatsapp_phone', whatsapp_phone,
    'logo_url',       logo_url
  )
  FROM public.shops
  WHERE id::text = p_shop_id
    AND is_active = true;
$$;

REVOKE ALL ON FUNCTION public.get_public_shop_info(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_shop_info(text)
  TO anon, authenticated;

COMMENT ON FUNCTION public.get_public_shop_info(text) IS
  'Retourne les infos publiques (id/name/phone/whatsapp_phone/logo_url) d''un '
  'shop actif pour la mini-vitrine catalogue. Bypass RLS. Voir hotfix_095/122.';

-- Recharge du cache PostgREST.
NOTIFY pgrst, 'reload schema';
