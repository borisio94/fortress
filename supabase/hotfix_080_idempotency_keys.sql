-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_080_idempotency_keys.sql
--
-- PR-A des 8 garde-fous stock — GF-1 (ventes) + GF-2 (transferts).
--
-- Ajoute une colonne `idempotency_key TEXT UNIQUE` sur `orders` et
-- `stock_transfers`. La clé est générée côté client (UUID v4) à
-- l'ouverture du panier / du formulaire de transfert. Le sync queue
-- offline-first peut rejouer le même INSERT plusieurs fois (double-tap,
-- reconnexion réseau, replay manuel) — la contrainte UNIQUE garantit
-- qu'UNE SEULE ligne est créée pour la même clé.
--
-- Étend également `place_public_order` (web orders) avec un paramètre
-- optionnel `p_idempotency_key` qui court-circuite l'INSERT si la clé
-- existe déjà et retourne l'order_id existant — protège contre les
-- re-soumissions de la page catalogue.
--
-- Idempotent : tous les ALTER utilisent IF NOT EXISTS, DROP FUNCTION
-- IF EXISTS avant CREATE pour la RPC, et les UNIQUE constraints sont
-- créées via `CREATE UNIQUE INDEX IF NOT EXISTS` (compatible PG13+).
-- ════════════════════════════════════════════════════════════════════════════

-- ─── 1. orders.idempotency_key ────────────────────────────────────────────
ALTER TABLE IF EXISTS public.orders
  ADD COLUMN IF NOT EXISTS idempotency_key TEXT;

-- UNIQUE partial index : ne contraint QUE les lignes avec une clé (les
-- ordres legacy pré-PR-A ont idempotency_key=NULL et restent intacts).
CREATE UNIQUE INDEX IF NOT EXISTS orders_idempotency_key_unique
  ON public.orders (idempotency_key)
  WHERE idempotency_key IS NOT NULL;

-- ─── 2. stock_transfers.idempotency_key ───────────────────────────────────
ALTER TABLE IF EXISTS public.stock_transfers
  ADD COLUMN IF NOT EXISTS idempotency_key TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS stock_transfers_idempotency_key_unique
  ON public.stock_transfers (idempotency_key)
  WHERE idempotency_key IS NOT NULL;

-- ─── 3. place_public_order : extension avec p_idempotency_key ─────────────
-- DROP de la signature actuelle (hotfix_079) avant le CREATE — sinon
-- Postgres refuse le changement de signature (paramètre ajouté).
DROP FUNCTION IF EXISTS public.place_public_order(
    text, jsonb, text, text, text, text, text, timestamptz, text);

CREATE OR REPLACE FUNCTION public.place_public_order(
  p_shop_id          text,
  p_items            jsonb,
  p_client_name      text,
  p_client_phone     text,
  p_client_city      text DEFAULT NULL,
  p_client_district  text DEFAULT NULL,
  p_notes            text DEFAULT NULL,
  p_scheduled_at     timestamptz DEFAULT NULL,
  p_location_id      text DEFAULT NULL,
  p_idempotency_key  text DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_existing_id   text;
  v_order_id      uuid := gen_random_uuid();
  v_shop_active   bool;
  v_shop_id_text  text;
  v_client_id     text;
  v_existing_name text;
  v_existing_city text;
  v_existing_dist text;
  v_phone         text := trim(p_client_phone);
  v_name          text := trim(p_client_name);
  v_city          text := NULLIF(trim(COALESCE(p_client_city, '')), '');
  v_dist          text := NULLIF(trim(COALESCE(p_client_district, '')), '');
  v_full_notes    text;
  v_loc_id        text := NULLIF(trim(COALESCE(p_location_id, '')), '');
  v_loc_ok        text;
  v_idem          text := NULLIF(trim(COALESCE(p_idempotency_key, '')), '');
BEGIN
  -- ── GF-1 : court-circuit idempotency_key ───────────────────────────────
  -- Si la clé est fournie ET déjà associée à un order, retourner cet id
  -- sans rien recréer. Permet à la page catalogue de re-soumettre sans
  -- risque (double-tap, retry réseau).
  IF v_idem IS NOT NULL THEN
    SELECT id::text INTO v_existing_id
      FROM orders WHERE idempotency_key = v_idem LIMIT 1;
    IF v_existing_id IS NOT NULL THEN
      RETURN v_existing_id;
    END IF;
  END IF;

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

  -- ── Validation emplacement (best-effort, type-safe) ───────────────────
  IF v_loc_id IS NOT NULL THEN
    SELECT id::text INTO v_loc_ok
      FROM stock_locations WHERE id::text = v_loc_id LIMIT 1;
  END IF;

  -- ── Upsert client par (store_id, phone) — comparaisons ::text ─────────
  SELECT id::text, name, city, district
    INTO v_client_id, v_existing_name, v_existing_city, v_existing_dist
    FROM clients
   WHERE store_id::text = v_shop_id_text AND phone = v_phone
   LIMIT 1;

  IF v_client_id IS NULL THEN
    INSERT INTO clients (
      id, store_id, name, phone, city, district,
      created_at, last_visit_at, is_archived
    )
    VALUES (
      gen_random_uuid()::text, v_shop_id_text, v_name, v_phone,
      v_city, v_dist,
      now(), now(), false
    )
    RETURNING id::text INTO v_client_id;
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
    WHERE id::text = v_client_id;

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
        'client', v_client_id, v_existing_name,
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

  -- ── INSERT order : source='web' + client_id + scheduled_at + loc + idem ──
  -- Note : `ON CONFLICT (idempotency_key) DO NOTHING` n'est pas utilisé ici
  -- car le court-circuit en début de fonction couvre déjà le cas. La
  -- contrainte UNIQUE reste un filet de sécurité ultime contre toute race.
  INSERT INTO orders (
    id, shop_id, status, items, fees,
    client_id, client_name, client_phone, notes,
    discount_amount, tax_rate, payment_method,
    source, scheduled_at, delivery_location_id, created_at,
    idempotency_key
  )
  VALUES (
    v_order_id::text, p_shop_id, 'scheduled', p_items, '[]'::jsonb,
    v_client_id, v_name, v_phone,
    NULLIF(v_full_notes, ''),
    0, 0, 'cash',
    'web', p_scheduled_at, v_loc_ok, now(),
    v_idem
  );

  RETURN v_order_id::text;
END;
$fn$;

REVOKE ALL ON FUNCTION public.place_public_order(
    text, jsonb, text, text, text, text, text, timestamptz, text, text)
    FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.place_public_order(
    text, jsonb, text, text, text, text, text, timestamptz, text, text)
    TO anon, authenticated;

-- ────────────────────────────────────────────────────────────────────────
-- Test manuel :
--   1) Appeler place_public_order avec p_idempotency_key = 'test-aaa-001'.
--      → renvoie un order_id.
--   2) Re-appeler exactement la même chose (même clé, items différents).
--      → renvoie LE MÊME order_id (court-circuit), pas de nouvel INSERT.
--   3) Vérifier : `SELECT count(*) FROM orders WHERE idempotency_key = 'test-aaa-001';`
--      → 1 (pas 2).
--   4) INSERT direct sur stock_transfers avec une clé déjà utilisée
--      → ERROR: duplicate key value violates unique constraint.
-- ────────────────────────────────────────────────────────────────────────
