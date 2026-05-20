-- hotfix_046_public_orders.sql
--
-- Permet à un client NON AUTHENTIFIÉ (rôle anon) de passer une commande
-- depuis la page publique `/catalogue/:shopId`. La RPC valide les inputs
-- côté serveur, insère la row dans `orders`, et déclenche les listeners
-- Realtime existants → le marchand reçoit la notification in-app
-- automatiquement (cf. `_emitOrderNotification` dans `app_database.dart`).
--
-- Sécurité :
--   • SECURITY DEFINER → bypass RLS pour l'INSERT (l'anon n'a aucun droit
--     direct sur la table orders).
--   • Validation stricte des arguments : nom et téléphone requis, items
--     non vide, shop existe et actif.
--   • Pas de retour de données sensibles — juste l'order_id.
--
-- Idempotent : sûr à ré-exécuter (CREATE OR REPLACE).

CREATE OR REPLACE FUNCTION public.place_public_order(
  p_shop_id        text,
  p_items          jsonb,
  p_client_name    text,
  p_client_phone   text,
  p_client_address text DEFAULT NULL,
  p_notes          text DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id           uuid := gen_random_uuid();
  v_shop_active  bool;
  v_full_notes   text;
BEGIN
  -- ── Validation inputs ─────────────────────────────────────────────────
  IF p_shop_id IS NULL OR length(trim(p_shop_id)) = 0 THEN
    RAISE EXCEPTION 'shop_id_required' USING ERRCODE = '22023';
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array'
     OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'items_required' USING ERRCODE = '22023';
  END IF;
  IF p_client_name IS NULL OR length(trim(p_client_name)) = 0 THEN
    RAISE EXCEPTION 'client_name_required' USING ERRCODE = '22023';
  END IF;
  IF p_client_phone IS NULL OR length(trim(p_client_phone)) = 0 THEN
    RAISE EXCEPTION 'client_phone_required' USING ERRCODE = '22023';
  END IF;

  -- ── Vérifie que la boutique existe et est active ──────────────────────
  -- On ne caste PAS p_shop_id en uuid : le type natif de `orders.shop_id`
  -- peut être text ou uuid selon les migrations historiques. On compare
  -- via `id::text` pour matcher dans les deux cas.
  SELECT is_active INTO v_shop_active
    FROM shops WHERE id::text = p_shop_id;
  IF v_shop_active IS NULL THEN
    RAISE EXCEPTION 'shop_not_found' USING ERRCODE = '42P01';
  END IF;
  IF v_shop_active = false THEN
    RAISE EXCEPTION 'shop_inactive' USING ERRCODE = '42P01';
  END IF;

  -- ── Compose les notes finales (adresse + notes libres) ───────────────
  v_full_notes := COALESCE(p_notes, '');
  IF p_client_address IS NOT NULL AND length(trim(p_client_address)) > 0 THEN
    IF length(v_full_notes) > 0 THEN
      v_full_notes := v_full_notes || E'\n';
    END IF;
    v_full_notes := v_full_notes || 'Adresse : ' || trim(p_client_address);
  END IF;

  -- ── INSERT order ──────────────────────────────────────────────────────
  -- shop_id : on passe p_shop_id (text). Postgres applique un cast
  -- implicite si la colonne est uuid (le format UUID est respecté).
  -- status = 'scheduled' : le marchand confirme manuellement après contact.
  INSERT INTO orders (
    id, shop_id, status, items, fees,
    client_name, client_phone, notes,
    discount_amount, tax_rate, payment_method,
    created_at
  )
  VALUES (
    v_id, p_shop_id, 'scheduled', p_items, '[]'::jsonb,
    trim(p_client_name), trim(p_client_phone),
    NULLIF(v_full_notes, ''),
    0, 0, 'cash',
    now()
  );

  RETURN v_id::text;
END;
$$;

REVOKE ALL ON FUNCTION public.place_public_order(
    text, jsonb, text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.place_public_order(
    text, jsonb, text, text, text, text) TO anon, authenticated;
