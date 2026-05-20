-- hotfix_057_order_tracking.sql
--
-- Permet aux clients de SUIVRE et VALIDER leur commande via un lien public
-- `/track/<order_id>` partagé par WhatsApp dans le message de relance.
--
-- Composants :
--   1. RPC `get_tracked_order(order_id)` (SECURITY DEFINER) — retourne les
--      infos commande + boutique pour une seule row donnée. Pas de SELECT
--      anon direct sur `orders` pour éviter les listings.
--   2. RPC `validate_order_by_client(order_id)` (SECURITY DEFINER) —
--      bascule status `scheduled` → `processing`. Idempotent. Trace dans
--      activity_logs avec source='public_link'.
--
-- Modèle de sécurité : l'UUID v4 du `order_id` (~128 bits d'entropie) sert
-- de bearer token. Il n'est partagé qu'avec le client via WhatsApp. Aucune
-- énumération possible (RPC paramétrée). Pas d'exposition des cost prices,
-- du payment_method, etc. — la RPC ne renvoie que les colonnes utiles à
-- l'affichage côté client.
--
-- Idempotent : DROP IF EXISTS avant CREATE.

-- ─── 1. RPC get_tracked_order ─────────────────────────────────────────────
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
    'items',           o.items,
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


-- ─── 2. RPC validate_order_by_client ──────────────────────────────────────
DROP FUNCTION IF EXISTS public.validate_order_by_client(text);

CREATE OR REPLACE FUNCTION public.validate_order_by_client(p_order_id text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_status  text;
  v_shop_id text;
BEGIN
  IF p_order_id IS NULL OR length(trim(p_order_id)) = 0 THEN
    RAISE EXCEPTION 'order_id_required' USING ERRCODE = '22023';
  END IF;

  SELECT status, shop_id
    INTO v_status, v_shop_id
    FROM orders
   WHERE id::text = p_order_id;

  IF v_status IS NULL THEN
    RAISE EXCEPTION 'order_not_found' USING ERRCODE = '42P01';
  END IF;

  -- Idempotent : déjà validée → retourne ok sans rien refaire.
  IF v_status = 'processing' THEN
    RETURN 'already_validated';
  END IF;

  -- Seules les commandes 'scheduled' peuvent être validées par le client.
  -- Les autres statuts (completed, cancelled, refused, refunded) sont des
  -- états finaux ou administratifs — pas modifiables côté client.
  IF v_status <> 'scheduled' THEN
    RAISE EXCEPTION 'order_not_validatable' USING ERRCODE = '22023';
  END IF;

  UPDATE orders
     SET status = 'processing'
   WHERE id::text = p_order_id;

  INSERT INTO activity_logs (
    id, action, target_type, target_id, target_label,
    shop_id, details, created_at
  )
  VALUES (
    gen_random_uuid(),
    'order_validated_by_client',
    'order', p_order_id, 'Commande validée par le client',
    v_shop_id::uuid,
    jsonb_build_object(
      'order_id', p_order_id,
      'source',   'public_link'
    ),
    now()
  );

  RETURN 'validated';
END;
$fn$;

REVOKE ALL ON FUNCTION public.validate_order_by_client(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.validate_order_by_client(text) TO anon, authenticated;
