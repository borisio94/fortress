-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_050_delivery_group.sql
--
-- Extension hotfix_049 : permet à un partenaire d'être contactable via un
-- GROUPE WhatsApp (au lieu d'un numéro 1-à-1). WhatsApp ne supporte pas le
-- deep-link `wa.me/<phone>?text=...` vers un groupe → workflow semi-manuel :
--
--   • La fiche partenaire stocke `chat.whatsapp.com/<code>` au lieu d'un phone.
--   • À l'envoi, le sheet copie le message dans le presse-papiers et ouvre
--     le lien d'invitation au groupe → l'utilisateur fait Ctrl+V dans le
--     groupe. La RPC `transfer_order_to_delivery` est appelée pareil
--     (status=processing + audit `messageSnapshot`).
--
-- Modifications :
--   1. stock_locations.whatsapp_group_url : nouvelle colonne text NULL.
--   2. delivery_transfers.target_phone     : rendu NULLABLE (groupe = pas
--      de phone à valider).
--   3. delivery_transfers.target_group_url : nouvelle colonne text NULL.
--   4. CHECK : au moins un des deux (target_phone OU target_group_url).
--   5. RPC `transfer_order_to_delivery` : nouvelle signature avec
--      `p_target_group_url`. Validation E.164 désactivée en mode groupe.
--
-- Idempotent.
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. stock_locations.whatsapp_group_url ────────────────────────────────────
ALTER TABLE stock_locations
  ADD COLUMN IF NOT EXISTS whatsapp_group_url text;

-- ── 2. delivery_transfers : target_phone nullable + target_group_url ─────────
ALTER TABLE delivery_transfers
  ALTER COLUMN target_phone DROP NOT NULL;

ALTER TABLE delivery_transfers
  ADD COLUMN IF NOT EXISTS target_group_url text;

-- CHECK : au moins un canal de contact (phone OU group_url) doit être fourni.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'delivery_transfers_contact_present'
  ) THEN
    ALTER TABLE delivery_transfers
      ADD CONSTRAINT delivery_transfers_contact_present
      CHECK (target_phone IS NOT NULL OR target_group_url IS NOT NULL);
  END IF;
END $$;

COMMIT;

-- ── 3. RPC v2 : `transfer_order_to_delivery` avec p_target_group_url ─────────
-- DROP de la signature précédente (7 args) pour éviter l'ambiguïté.
DROP FUNCTION IF EXISTS public.transfer_order_to_delivery(
    text, text, text, text, text, uuid, text);

CREATE OR REPLACE FUNCTION public.transfer_order_to_delivery(
  p_order_id         text,
  p_target_type      text,
  p_target_ref       text,
  p_target_name      text,
  p_target_phone     text,             -- NULL si mode groupe
  p_template_id      uuid,
  p_message_snapshot text,
  p_target_group_url text DEFAULT NULL  -- NULL si mode 1-à-1
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
  -- Validation E.164 uniquement si phone fourni (mode 1-à-1).
  IF v_phone IS NOT NULL AND v_phone !~ '^\+[1-9][0-9]{6,14}$' THEN
    RAISE EXCEPTION 'phone_invalid_e164' USING ERRCODE = '22023';
  END IF;
  -- Validation lien d'invitation WhatsApp (forme stricte mais permissive).
  IF v_group IS NOT NULL
     AND v_group !~ '^https://chat\.whatsapp\.com/[A-Za-z0-9]+$' THEN
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

REVOKE ALL ON FUNCTION public.transfer_order_to_delivery(
    text, text, text, text, text, uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.transfer_order_to_delivery(
    text, text, text, text, text, uuid, text, text) TO authenticated;
