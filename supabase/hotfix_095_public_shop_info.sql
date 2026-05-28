-- ═════════════════════════════════════════════════════════════════════════════
-- hotfix_095 — RPC SECURITY DEFINER `get_public_shop_info`.
--
-- Contexte : la page `/catalogue/:shopId` lit les infos boutique (nom,
-- téléphone, whatsapp_phone) via `from('shops').select(...).eq('id', X)`.
-- Cette lecture est régie par les policies RLS de `shops` :
--   • `shops_anon_read_active`        (TO anon)          → is_active = true
--   • `shops_select_owner_or_member`  (TO authenticated) → owner OU membre
--
-- Conséquence : un utilisateur AUTHENTIFIÉ NON-MEMBRE du shop ne matche
-- aucune policy SELECT → la requête retourne null → la CataloguePage
-- affiche "Boutique introuvable". Reproductible quand le marchand ouvre
-- son propre lien dans un browser mobile où il est connecté sur un compte
-- qui n'est pas membre du shop testé (compte perso vs compte boutique,
-- super-admin, etc.).
--
-- Sur desktop ça marche : le browser de test est anonyme (pas de session
-- Supabase persistée) → role anon → policy `shops_anon_read_active` passe.
--
-- Solution : un RPC SECURITY DEFINER qui retourne les colonnes publiques
-- d'un shop actif, bypass RLS, sans modifier les policies existantes (donc
-- l'isolation marchand inter-shops reste préservée).
--
-- Modèle de sécurité : l'accès est protégé par la connaissance de l'UUID
-- du shop (mêmes garanties que les liens publics catalogue existants).
-- Aligné avec le pattern hotfix_094 (`get_delivery_products`).
--
-- Idempotent : DROP IF EXISTS avant CREATE.
-- ═════════════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS public.get_public_shop_info(text);

CREATE FUNCTION public.get_public_shop_info(p_shop_id text)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  -- Retour en jsonb (cf. hotfix_094) pour éviter les ERROR 42804 si une
  -- colonne diverge en type (uuid/varchar/text). PG sérialise tout en
  -- JSON automatiquement, Dart récupère un Map<String, dynamic>.
  SELECT jsonb_build_object(
    'id',             id,
    'name',           name,
    'phone',          phone,
    'whatsapp_phone', whatsapp_phone
  )
  FROM public.shops
  WHERE id::text = p_shop_id
    AND is_active = true;
$$;

-- Grant explicite (anon + authenticated). Le SECURITY DEFINER bypasse déjà
-- RLS, donc le grant suffit pour autoriser l'appel.
REVOKE ALL ON FUNCTION public.get_public_shop_info(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_shop_info(text)
  TO anon, authenticated;

COMMENT ON FUNCTION public.get_public_shop_info(text) IS
  'Retourne les infos publiques (id/name/phone/whatsapp_phone) d''un shop '
  'actif pour la mini-vitrine catalogue. Bypass RLS pour servir aussi '
  'les utilisateurs authentifiés non-membres. Voir hotfix_095.';
