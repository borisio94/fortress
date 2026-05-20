-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_052_group_url_query.sql
--
-- Met à jour la regex de validation `target_group_url` dans la RPC
-- `transfer_order_to_delivery` pour autoriser un query string optionnel
-- ajouté par WhatsApp (`?mode=gi_t`, `?mode=ac_t`, etc.). Sans ça, les
-- liens d'invitation copiés depuis l'app WhatsApp officielle sont
-- rejetés avec ERRCODE 22023 (`group_url_invalid`).
--
-- Aucune autre modif : signature, perm check, audit insert restent
-- identiques à hotfix_050.
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.transfer_order_to_delivery(
  p_order_id         text,
  p_target_type      text,
  p_target_ref       text,
  p_target_name      text,
  p_target_phone     text,
  p_template_id      uuid,
  p_message_snapshot text,
  p_target_group_url text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_shop_id     text;
  v_status      text;
  v_user_id     uuid := auth.uid();
  v_transfer_id uuid := gen_random_uuid();
  v_phone       text := NULLIF(trim(coalesce(p_target_phone, '')), '');
  v_group       text := NULLIF(trim(coalesce(p_target_group_url, '')), '');
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = '42501';
  END IF;
  IF p_target_type NOT IN ('partner','employee','free') THEN
    RAISE EXCEPTION 'target_type_invalid' USING ERRCODE = '22023';
  END IF;
  IF v_phone IS NULL AND v_group IS NULL THEN
    RAISE EXCEPTION 'contact_required' USING ERRCODE = '22023';
  END IF;
  IF v_phone IS NOT NULL AND v_phone !~ '^\+[1-9][0-9]{6,14}$' THEN
    RAISE EXCEPTION 'phone_invalid_e164' USING ERRCODE = '22023';
  END IF;
  -- Validation lien d'invitation WhatsApp : autorise un query string
  -- optionnel (`?mode=gi_t`, `?mode=ac_t`…) ajouté par WhatsApp.
  IF v_group IS NOT NULL
     AND v_group !~ '^https://chat\.whatsapp\.com/[A-Za-z0-9]+(\?[A-Za-z0-9_=&\-]*)?$' THEN
    RAISE EXCEPTION 'group_url_invalid' USING ERRCODE = '22023';
  END IF;
  IF length(trim(coalesce(p_target_name, ''))) = 0 THEN
    RAISE EXCEPTION 'target_name_required' USING ERRCODE = '22023';
  END IF;
  IF length(trim(coalesce(p_message_snapshot, ''))) = 0 THEN
    RAISE EXCEPTION 'message_required' USING ERRCODE = '22023';
  END IF;

  SELECT shop_id, status INTO v_shop_id, v_status
    FROM orders WHERE id = p_order_id;
  IF v_shop_id IS NULL THEN
    RAISE EXCEPTION 'order_not_found' USING ERRCODE = '42P01';
  END IF;
  IF v_status <> 'scheduled' THEN
    RAISE EXCEPTION 'order_not_scheduled' USING ERRCODE = '22023';
  END IF;

  IF NOT public._user_has_permission(v_shop_id, 'delivery.send_whatsapp') THEN
    RAISE EXCEPTION 'delivery_transfer_forbidden' USING ERRCODE = '42501';
  END IF;

  UPDATE orders SET status = 'processing' WHERE id = p_order_id;

  INSERT INTO delivery_transfers
    (id, order_id, shop_id, sender_user_id, target_type, target_ref,
     target_name, target_phone, target_group_url,
     template_id, message_snapshot, created_at)
  VALUES
    (v_transfer_id, p_order_id, v_shop_id, v_user_id, p_target_type,
     NULLIF(trim(coalesce(p_target_ref, '')), ''),
     trim(p_target_name), v_phone, v_group,
     p_template_id, p_message_snapshot, now());

  RETURN v_transfer_id;
END;
$fn$;
