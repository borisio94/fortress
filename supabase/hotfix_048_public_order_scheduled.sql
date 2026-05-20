-- hotfix_048_public_order_scheduled.sql
--
-- Évolution `place_public_order` v3 :
--   • Ajoute le paramètre `p_scheduled_at timestamptz` (date de livraison
--     souhaitée par le client). Stocké tel quel dans `orders.scheduled_at`.
--   • Permet ainsi à la commande web d'apparaître dans la liste comme une
--     commande "normale" : le marchand voit la date et peut cliquer sur
--     "modifier" pour charger le panier (items + client + scheduled_at)
--     via `LoadOrderForEdit` (cf. caisse_bloc.dart).
--   • Conserve TOUTES les garanties de v2 (validation E.164, upsert client
--     préservatif, log mismatch, source='web', client_id lié).
--
-- DROP+CREATE de la précédente signature pour éviter l'ambiguïté de
-- résolution si on appelle avec des arguments nommés.
--
-- Idempotent.

DROP FUNCTION IF EXISTS public.place_public_order(
    text, jsonb, text, text, text, text, text);

CREATE OR REPLACE FUNCTION public.place_public_order(
  p_shop_id          text,
  p_items            jsonb,
  p_client_name      text,
  p_client_phone     text,
  p_client_city      text DEFAULT NULL,
  p_client_district  text DEFAULT NULL,
  p_notes            text DEFAULT NULL,
  p_scheduled_at     timestamptz DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_order_id      uuid := gen_random_uuid();
  v_shop_active   bool;
  v_shop_id_text  text;
  v_client_id     uuid;
  v_existing_name text;
  v_existing_city text;
  v_existing_dist text;
  v_phone         text := trim(p_client_phone);
  v_name          text := trim(p_client_name);
  v_city          text := NULLIF(trim(COALESCE(p_client_city, '')), '');
  v_dist          text := NULLIF(trim(COALESCE(p_client_district, '')), '');
  v_full_notes    text;
BEGIN
  -- ── Validation inputs ──────────────────────────────────────────────────
  IF p_shop_id IS NULL OR length(trim(p_shop_id)) = 0 THEN
    RAISE EXCEPTION 'shop_id_required' USING ERRCODE = '22023';
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array'
     OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'items_required' USING ERRCODE = '22023';
  END IF;
  IF v_name = '' THEN
    RAISE EXCEPTION 'client_name_required' USING ERRCODE = '22023';
  END IF;
  IF v_phone = '' THEN
    RAISE EXCEPTION 'client_phone_required' USING ERRCODE = '22023';
  END IF;
  IF v_phone !~ '^\+[1-9][0-9]{6,14}$' THEN
    RAISE EXCEPTION 'client_phone_invalid_e164' USING ERRCODE = '22023';
  END IF;

  -- ── Boutique existante et active ──────────────────────────────────────
  SELECT id::text, is_active
    INTO v_shop_id_text, v_shop_active
    FROM shops WHERE id::text = p_shop_id;
  IF v_shop_id_text IS NULL THEN
    RAISE EXCEPTION 'shop_not_found' USING ERRCODE = '42P01';
  END IF;
  IF v_shop_active = false THEN
    RAISE EXCEPTION 'shop_inactive' USING ERRCODE = '42P01';
  END IF;

  -- ── Upsert client par (store_id, phone) ───────────────────────────────
  SELECT id, name, city, district
    INTO v_client_id, v_existing_name, v_existing_city, v_existing_dist
    FROM clients
   WHERE store_id = v_shop_id_text AND phone = v_phone
   LIMIT 1;

  IF v_client_id IS NULL THEN
    INSERT INTO clients (
      id, store_id, name, phone, city, district,
      created_at, last_visit_at, is_archived
    )
    VALUES (
      gen_random_uuid(), v_shop_id_text, v_name, v_phone,
      v_city, v_dist,
      now(), now(), false
    )
    RETURNING id INTO v_client_id;
  ELSE
    UPDATE clients SET
      city = CASE
        WHEN (v_existing_city IS NULL OR length(trim(v_existing_city)) = 0)
             AND v_city IS NOT NULL THEN v_city
        ELSE city END,
      district = CASE
        WHEN (v_existing_dist IS NULL OR length(trim(v_existing_dist)) = 0)
             AND v_dist IS NOT NULL THEN v_dist
        ELSE district END,
      last_visit_at = now()
    WHERE id = v_client_id;

    IF v_existing_name IS NOT NULL
       AND length(trim(v_existing_name)) > 0
       AND lower(trim(v_existing_name)) <> lower(v_name) THEN
      INSERT INTO activity_logs (
        id, action, target_type, target_id, target_label,
        shop_id, details, created_at
      )
      VALUES (
        gen_random_uuid(),
        'client_name_mismatch_on_web_order',
        'client', v_client_id::text, v_existing_name,
        v_shop_id_text::uuid,
        jsonb_build_object(
          'existing_name', v_existing_name,
          'incoming_name', v_name,
          'phone',         v_phone,
          'order_id',      v_order_id::text
        ),
        now()
      );
    END IF;
  END IF;

  -- ── Compose notes finales (adresse depuis quartier + ville) ───────────
  v_full_notes := COALESCE(p_notes, '');
  IF v_dist IS NOT NULL OR v_city IS NOT NULL THEN
    IF length(v_full_notes) > 0 THEN
      v_full_notes := v_full_notes || E'\n';
    END IF;
    v_full_notes := v_full_notes || 'Adresse : '
      || COALESCE(v_dist || ', ', '') || COALESCE(v_city, '');
  END IF;

  -- ── INSERT order : source='web' + client_id + scheduled_at ────────────
  INSERT INTO orders (
    id, shop_id, status, items, fees,
    client_id, client_name, client_phone, notes,
    discount_amount, tax_rate, payment_method,
    source, scheduled_at, created_at
  )
  VALUES (
    v_order_id, p_shop_id, 'scheduled', p_items, '[]'::jsonb,
    v_client_id::text, v_name, v_phone,
    NULLIF(v_full_notes, ''),
    0, 0, 'cash',
    'web', p_scheduled_at, now()
  );

  RETURN v_order_id::text;
END;
$fn$;

REVOKE ALL ON FUNCTION public.place_public_order(
    text, jsonb, text, text, text, text, text, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.place_public_order(
    text, jsonb, text, text, text, text, text, timestamptz) TO anon, authenticated;
