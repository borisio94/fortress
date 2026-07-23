-- hotfix_139_restaurant_public_order.sql
-- ═════════════════════════════════════════════════════════════════════════
-- MODULE RESTAURANT — PR-4 : commandes publiques typées + secteur exposé.
--
-- 1. `get_public_shop_info` expose `sector` → le catalogue web statique peut
--    savoir qu'il s'agit d'un restaurant et basculer en présentation menu.
--    Donnée non sensible (elle ne dit rien de plus que l'enseigne elle-même).
--
-- 2. `place_public_order` reçoit `p_order_type` → une commande passée depuis
--    le catalogue d'un restaurant arrive en `takeaway` explicite, et une
--    commande e-commerce livrée peut être typée `delivery`. Sans ça, TOUTES
--    les commandes publiques héritaient du DEFAULT 'takeaway' de la colonne,
--    ce qui faussait les statistiques par canal et l'index cuisine.
--
-- ⚠ PIÈGE DE SURCHARGE — leçon de hotfix_134.
-- `CREATE OR REPLACE FUNCTION` avec une liste de paramètres DIFFÉRENTE crée
-- une NOUVELLE surcharge au lieu de remplacer. Les deux versions coexistent
-- alors, et un appel PostgREST devient ambigu → `PGRST203` (« could not
-- choose the best candidate function »). C'est exactement le désordre que
-- hotfix_134 a dû nettoyer (5 versions accumulées de 046 à 080).
--
-- On DROP donc explicitement la version 13-paramètres avant de créer la
-- version 14-paramètres. Comme le nouveau paramètre a un DEFAULT, les
-- appelants qui envoient encore 13 arguments continuent de fonctionner et
-- résolvent sans ambiguïté vers l'unique version restante.
--
-- 100 % idempotent.
-- ═════════════════════════════════════════════════════════════════════════

-- ── 1. Secteur exposé au catalogue public ────────────────────────────────
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
    'facebook_pixel_id', facebook_pixel_id,
    'sector',            sector
  )
  FROM public.shops
  WHERE id::text = p_shop_id
    AND is_active = true;
$$;

REVOKE ALL ON FUNCTION public.get_public_shop_info(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_shop_info(text)
  TO anon, authenticated;

-- ── 2. Commande publique typée ───────────────────────────────────────────
-- DROP de la version 13-paramètres (hotfix_129) AVANT création, sinon les
-- deux surcharges coexistent (cf. avertissement en tête de fichier).
DROP FUNCTION IF EXISTS public.place_public_order(
  text, jsonb, text, text, text, text, text, timestamptz, text, text,
  int, text, text);

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
  p_idempotency_key  text DEFAULT NULL,
  p_delivery_price   int  DEFAULT NULL,
  p_delivery_quartier text DEFAULT NULL,
  p_delivery_zone    text DEFAULT NULL,
  p_order_type       text DEFAULT 'takeaway'
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
  v_quartier      text := NULLIF(trim(COALESCE(p_delivery_quartier, '')), '');
  v_zone          text := NULLIF(trim(COALESCE(p_delivery_zone, '')), '');
  v_order_type    text;
BEGIN
  -- Le type est VALIDÉ ici et non délégué au CHECK de la colonne : une
  -- valeur inattendue venant d'un client public doit retomber sur un défaut
  -- sûr plutôt que faire échouer la commande d'un client final.
  v_order_type := lower(NULLIF(trim(COALESCE(p_order_type, '')), ''));
  IF v_order_type IS NULL
     OR v_order_type NOT IN ('dine_in', 'takeaway', 'delivery') THEN
    v_order_type := 'takeaway';
  END IF;
  -- `dine_in` est réservé au service en salle, saisi par un serveur
  -- authentifié. Un client public ne peut pas s'auto-attribuer une table.
  IF v_order_type = 'dine_in' THEN
    v_order_type := 'takeaway';
  END IF;

  IF v_idem IS NOT NULL THEN
    SELECT id::text INTO v_existing_id
      FROM orders WHERE idempotency_key = v_idem LIMIT 1;
    IF v_existing_id IS NOT NULL THEN
      RETURN v_existing_id;
    END IF;
  END IF;

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

  SELECT id::text, is_active
    INTO v_shop_id_text, v_shop_active
    FROM shops WHERE id::text = p_shop_id;
  IF v_shop_id_text IS NULL THEN
    RAISE EXCEPTION 'shop_not_found' USING ERRCODE = '42P01';
  END IF;
  IF v_shop_active = false THEN
    RAISE EXCEPTION 'shop_inactive' USING ERRCODE = '42P01';
  END IF;

  IF v_loc_id IS NOT NULL THEN
    SELECT id::text INTO v_loc_ok
      FROM stock_locations WHERE id::text = v_loc_id LIMIT 1;
  END IF;

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
    UPDATE clients
       SET last_visit_at = now(),
           city     = COALESCE(v_city, city),
           district = COALESCE(v_dist, district)
     WHERE id::text = v_client_id;

    IF v_existing_name IS NOT NULL
       AND lower(trim(v_existing_name)) <> lower(v_name) THEN
      INSERT INTO activity_logs (
        id, user_id, action, target_type, target_id, target_label,
        shop_id, details, created_at
      )
      VALUES (
        gen_random_uuid()::text, NULL,
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

  v_full_notes := COALESCE(p_notes, '');
  IF v_dist IS NOT NULL OR v_city IS NOT NULL THEN
    IF length(v_full_notes) > 0 THEN
      v_full_notes := v_full_notes || E'\n';
    END IF;
    v_full_notes := v_full_notes || 'Adresse : '
      || COALESCE(v_dist || ', ', '') || COALESCE(v_city, '');
  END IF;

  -- INSERT order : + champs livraison + order_type (hotfix_139).
  INSERT INTO orders (
    id, shop_id, status, items, fees,
    client_id, client_name, client_phone, notes,
    discount_amount, tax_rate, payment_method,
    source, scheduled_at, delivery_location_id, created_at,
    idempotency_key,
    delivery_city, delivery_quartier, delivery_price, delivery_zone,
    order_type
  )
  VALUES (
    v_order_id::text, p_shop_id, 'scheduled', p_items, '[]'::jsonb,
    v_client_id, v_name, v_phone,
    NULLIF(v_full_notes, ''),
    0, 0, 'cash',
    'web', p_scheduled_at, v_loc_ok, now(),
    v_idem,
    v_city, COALESCE(v_quartier, v_dist), p_delivery_price, v_zone,
    v_order_type
  );

  RETURN v_order_id::text;
END;
$fn$;

REVOKE ALL ON FUNCTION public.place_public_order(
    text, jsonb, text, text, text, text, text, timestamptz, text, text,
    int, text, text, text)
    FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.place_public_order(
    text, jsonb, text, text, text, text, text, timestamptz, text, text,
    int, text, text, text)
    TO anon, authenticated;

-- Recharge du cache PostgREST (obligatoire après changement de signature).
NOTIFY pgrst, 'reload schema';

-- ── Vérification ──────────────────────────────────────────────────────────
--   -- Doit renvoyer UNE SEULE ligne (sinon surcharges = PGRST203) :
--   SELECT p.oid::regprocedure AS signature
--     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--    WHERE n.nspname='public' AND p.proname='place_public_order';
--
--   SELECT public.get_public_shop_info('<shop_id>') -> 'sector';
--
-- Fin — hotfix_139_restaurant_public_order.sql
