-- ═════════════════════════════════════════════════════════════════════════════
-- hotfix_125 — Pixel Facebook par boutique (suivi des conversions catalogue).
--
-- Contexte : un commerçant peut connecter son Pixel Meta depuis
-- Paramètres → Marketing → Facebook. L'ID est stocké sur `shops` puis exposé
-- via le RPC public `get_public_shop_info` pour que la page `/catalogue/:shopId`
-- injecte le pixel et remonte les évènements (PageView, ViewContent, AddToCart,
-- Purchase) vers Meta.
--
-- L'ID de pixel n'est PAS une donnée sensible : il est conçu pour vivre dans le
-- HTML public d'une page (c'est un identifiant de tracking côté client).
-- L'exposer via le RPC public est donc volontaire et sans risque (aucun prix
-- d'achat / marge / fournisseur n'est concerné).
--
-- Idempotent : ADD COLUMN IF NOT EXISTS + CREATE OR REPLACE (même signature).
-- NOTIFY pgrst en fin (sinon PostgREST répond PGRST204 « column does not exist »).
-- ═════════════════════════════════════════════════════════════════════════════

-- 1) Colonne (nullable, optionnelle).
ALTER TABLE public.shops
  ADD COLUMN IF NOT EXISTS facebook_pixel_id text;

-- 2) Exposer l'ID dans les infos publiques de la mini-vitrine catalogue.
CREATE OR REPLACE FUNCTION public.get_public_shop_info(p_shop_id text)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'id',                id,
    'name',              name,
    'phone',             phone,
    'whatsapp_phone',    whatsapp_phone,
    'logo_url',          logo_url,
    'facebook_pixel_id', facebook_pixel_id
  )
  FROM public.shops
  WHERE id::text = p_shop_id
    AND is_active = true;
$$;

REVOKE ALL ON FUNCTION public.get_public_shop_info(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_shop_info(text)
  TO anon, authenticated;

COMMENT ON FUNCTION public.get_public_shop_info(text) IS
  'Retourne les infos publiques (id/name/phone/whatsapp_phone/logo_url/'
  'facebook_pixel_id) d''un shop actif pour la mini-vitrine catalogue. '
  'Bypass RLS. Voir hotfix_095/122/125.';

-- Recharge du cache PostgREST.
NOTIFY pgrst, 'reload schema';
