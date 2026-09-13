-- hotfix_172_tracked_order_privacy.sql
-- ═════════════════════════════════════════════════════════════════════════
-- CE QUE LA PAGE DE SUIVI A LE DROIT DE MONTRER.
--
-- `get_tracked_order` est accordée au rôle anonyme : qui connaît la clé lit
-- la commande. Elle renvoyait jusqu'ici le téléphone du client en clair et
-- les notes — lesquelles contiennent l'adresse de livraison, injectée par
-- `place_public_order` sous la forme « Adresse : … ».
--
-- Trois corrections, indissociables :
--
-- 1. LA CLÉ. La fonction accepte désormais le `tracking_token` (hotfix_171)
--    EN PLUS de l'identifiant. Le paramètre garde son nom `p_order_id` pour
--    que les pages publiques déjà déployées continuent de fonctionner sans
--    modification, et que les anciens liens restent lisibles.
--
-- 2. LES SUPPRIMÉES. Aucun filtre `deleted_at` n'existait : une commande
--    supprimée restait publiquement consultable. Elle ne l'est plus.
--
-- 3. LES DONNÉES PERSONNELLES. Le téléphone est réduit à ses deux derniers
--    chiffres, les notes ne sont plus renvoyées du tout. Le client reconnaît
--    sa commande par son nom, ses articles et son total — cela suffit à un
--    suivi. Même si une clé fuite, l'adresse et le numéro ne fuitent plus.
--    `client_name` et `shop_phone` restent : le premier est le repère du
--    client, le second est une donnée publique de la boutique.
--
-- `_strip_item_secrets` (hotfix_101) continue de retirer `price_buy` des
-- lignes : le prix d'achat n'a jamais eu à sortir.
--
-- 100 % idempotent (CREATE OR REPLACE, signature inchangée).
-- ═════════════════════════════════════════════════════════════════════════

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
    'items',           public._strip_item_secrets(o.items),
    'discount_amount', o.discount_amount,
    'tax_rate',        o.tax_rate,
    'client_name',     o.client_name,
    -- Masqué : deux derniers chiffres seulement. Assez pour que le client
    -- reconnaisse son numéro, trop peu pour qu'un tiers l'utilise.
    'client_phone',    CASE
                         WHEN o.client_phone IS NULL
                           OR length(trim(o.client_phone)) < 2 THEN NULL
                         ELSE '•• •• •• •• ' || right(trim(o.client_phone), 2)
                       END,
    -- Retiré : les notes portent l'adresse de livraison.
    'notes',           NULL,
    'scheduled_at',    o.scheduled_at,
    'created_at',      o.created_at,
    'shop_name',       s.name,
    'shop_phone',      s.phone
  )
    INTO v_row
    FROM orders o
    JOIN shops  s ON s.id::text = o.shop_id
   -- Jeton d'abord (lien émis depuis hotfix_171), identifiant ensuite
   -- (anciens liens déjà envoyés aux clients — lecture seule).
   WHERE (o.tracking_token = p_order_id OR o.id::text = p_order_id)
     AND o.deleted_at IS NULL
     AND s.is_active = true;

  IF v_row IS NULL THEN
    RAISE EXCEPTION 'order_not_found' USING ERRCODE = '42P01';
  END IF;

  RETURN v_row;
END;
$fn$;

REVOKE ALL    ON FUNCTION public.get_tracked_order(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_tracked_order(text) TO anon, authenticated;
