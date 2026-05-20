-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_054_partner_depots_phase_b.sql
--
-- Phase B de la promotion des partenaires en boutiques satellites.
--
-- Fournit deux RPC :
--   1. convert_partner_to_depot(...) — convertit une StockLocation type=
--      'partner' en `shops kind='partner_depot'` rattachée à une main shop,
--      migre les stock_levels, désactive l'ancienne location.
--   2. rollback_convert_partner(...) — annule la conversion.
--
-- À ne PAS exécuter automatiquement sur les partenaires existants.
-- L'opération est déclenchée manuellement (UI à venir, ou appel SQL direct).
-- L'ancienne location reste en base avec is_active=false pour rollback aisé.
--
-- Idempotent (CREATE OR REPLACE).
-- Pré-requis : hotfix_053 (kind, parent_shop_id, product_visibility) appliqué.
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1. Conversion partenaire → boutique satellite ────────────────────────
CREATE OR REPLACE FUNCTION public.convert_partner_to_depot(
  p_location_id    text,
  p_parent_shop_id text,
  p_new_shop_name  text DEFAULT NULL,  -- override; défaut = location.name
  p_admin_user_id  text DEFAULT NULL   -- admin à ajouter automatiquement
) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_caller       uuid := auth.uid();
  v_loc          stock_locations%ROWTYPE;
  v_parent       shops%ROWTYPE;
  v_new_shop_id  text;
  v_new_loc_id   text;
  v_new_name     text;
  v_admin_clean  text;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = '42501';
  END IF;

  -- Charger la location partenaire
  SELECT * INTO v_loc FROM stock_locations WHERE id = p_location_id;
  IF v_loc.id IS NULL THEN
    RAISE EXCEPTION 'location_not_found' USING ERRCODE = '42P01';
  END IF;
  IF v_loc.type <> 'partner' THEN
    RAISE EXCEPTION 'location_not_partner' USING ERRCODE = '22023';
  END IF;
  IF v_loc.is_active IS NOT TRUE THEN
    RAISE EXCEPTION 'location_inactive' USING ERRCODE = '22023';
  END IF;
  IF v_loc.owner_id <> v_caller::text THEN
    RAISE EXCEPTION 'location_not_owned' USING ERRCODE = '42501';
  END IF;

  -- Charger et valider la boutique parent (main, owned by caller)
  SELECT * INTO v_parent FROM shops WHERE id::text = p_parent_shop_id;
  IF v_parent.id IS NULL THEN
    RAISE EXCEPTION 'parent_shop_not_found' USING ERRCODE = '42P01';
  END IF;
  IF v_parent.owner_id::text <> v_caller::text THEN
    RAISE EXCEPTION 'parent_not_owned' USING ERRCODE = '42501';
  END IF;
  IF v_parent.kind <> 'main' THEN
    RAISE EXCEPTION 'parent_not_main' USING ERRCODE = '22023';
  END IF;

  v_new_name    := COALESCE(NULLIF(trim(p_new_shop_name), ''), v_loc.name);
  v_admin_clean := NULLIF(trim(coalesce(p_admin_user_id, '')), '');

  v_new_shop_id := gen_random_uuid()::text;
  v_new_loc_id  := gen_random_uuid()::text;

  -- Créer la boutique satellite (hérite currency/country/sector du parent)
  INSERT INTO shops (id, name, currency, country, sector, owner_id,
                     phone, email, is_active, created_at,
                     kind, parent_shop_id)
  VALUES (v_new_shop_id, v_new_name, v_parent.currency, v_parent.country,
          v_parent.sector, v_caller::text,
          v_loc.phone, NULL, true, now(),
          'partner_depot', p_parent_shop_id);

  -- Membership owner (caller)
  INSERT INTO shop_memberships (shop_id, user_id, role, permissions,
                                status, created_at)
  SELECT v_new_shop_id, v_caller::text, 'owner', '[]'::jsonb,
         'active', now()
   WHERE NOT EXISTS (
     SELECT 1 FROM shop_memberships
      WHERE shop_id::text = v_new_shop_id
        AND user_id::text = v_caller::text);

  -- Membership admin optionnel
  IF v_admin_clean IS NOT NULL THEN
    INSERT INTO shop_memberships (shop_id, user_id, role, permissions,
                                  status, created_at)
    SELECT v_new_shop_id, v_admin_clean, 'admin', '[]'::jsonb,
           'active', now()
     WHERE NOT EXISTS (
       SELECT 1 FROM shop_memberships
        WHERE shop_id::text = v_new_shop_id
          AND user_id::text = v_admin_clean);
  END IF;

  -- StockLocation type='shop' pour la nouvelle boutique
  INSERT INTO stock_locations (id, owner_id, type, name, shop_id,
                               address, city, district, phone,
                               contact_name, notes, is_active, created_at,
                               delivery_template_id, whatsapp_group_url)
  VALUES (v_new_loc_id, v_caller::text, 'shop', v_new_name, v_new_shop_id,
          v_loc.address, v_loc.city, v_loc.district, v_loc.phone,
          v_loc.contact_name, v_loc.notes, true, now(),
          v_loc.delivery_template_id, v_loc.whatsapp_group_url);

  -- Migrer les stock_levels de l'ancienne location vers la nouvelle.
  -- Le UNIQUE(variant_id, location_id) nous protège des doublons.
  UPDATE stock_levels
     SET location_id = v_new_loc_id,
         shop_id     = v_new_shop_id,
         updated_at  = now()
   WHERE location_id = p_location_id;

  -- Désactiver l'ancienne location partenaire (rollback-friendly).
  UPDATE stock_locations
     SET is_active = false
   WHERE id = p_location_id;

  -- Audit log : conserver le lien origin_location_id pour le rollback
  INSERT INTO activity_logs
    (actor_id, action, target_type, target_id, target_label,
     shop_id, details)
  VALUES (v_caller, 'shop.partner_promoted', 'shop',
          v_new_shop_id, v_new_name,
          v_new_shop_id::uuid,
          jsonb_build_object(
            'source',             'convert_partner_to_depot',
            'origin_location_id', p_location_id,
            'origin_location_name', v_loc.name,
            'parent_shop_id',     p_parent_shop_id,
            'admin_user_id',      v_admin_clean));

  RETURN v_new_shop_id;
END;
$fn$;

REVOKE ALL ON FUNCTION public.convert_partner_to_depot(text,text,text,text)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.convert_partner_to_depot(text,text,text,text)
  TO authenticated;

-- ── 2. Rollback de la conversion ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rollback_convert_partner(
  p_new_shop_id text
) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_caller     uuid := auth.uid();
  v_shop       shops%ROWTYPE;
  v_old_loc_id text;
  v_new_loc_id text;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_shop FROM shops WHERE id::text = p_new_shop_id;
  IF v_shop.id IS NULL THEN
    RAISE EXCEPTION 'shop_not_found' USING ERRCODE = '42P01';
  END IF;
  IF v_shop.kind <> 'partner_depot' THEN
    RAISE EXCEPTION 'shop_not_partner_depot' USING ERRCODE = '22023';
  END IF;
  IF v_shop.owner_id::text <> v_caller::text THEN
    RAISE EXCEPTION 'not_owner' USING ERRCODE = '42501';
  END IF;

  -- StockLocation type='shop' de la nouvelle boutique
  SELECT id INTO v_new_loc_id
    FROM stock_locations
   WHERE shop_id::text = p_new_shop_id AND type = 'shop'
   LIMIT 1;

  -- Récupérer l'origin_location_id depuis l'audit log
  SELECT details->>'origin_location_id' INTO v_old_loc_id
    FROM activity_logs
   WHERE shop_id = v_shop.id::uuid
     AND action  = 'shop.partner_promoted'
     AND details->>'source' = 'convert_partner_to_depot'
   ORDER BY created_at DESC
   LIMIT 1;

  IF v_old_loc_id IS NULL THEN
    RAISE EXCEPTION 'origin_location_not_found' USING ERRCODE = '42P01';
  END IF;

  -- Restaurer les stock_levels vers l'ancienne location
  IF v_new_loc_id IS NOT NULL THEN
    UPDATE stock_levels
       SET location_id = v_old_loc_id,
           shop_id     = NULL,
           updated_at  = now()
     WHERE location_id = v_new_loc_id;
  END IF;

  -- Réactiver l'ancienne location
  UPDATE stock_locations
     SET is_active = true
   WHERE id = v_old_loc_id;

  -- Supprimer la nouvelle stock_location
  IF v_new_loc_id IS NOT NULL THEN
    DELETE FROM stock_locations WHERE id = v_new_loc_id;
  END IF;

  -- Supprimer les memberships de la nouvelle shop
  DELETE FROM shop_memberships WHERE shop_id::text = p_new_shop_id;

  -- Supprimer la shop
  DELETE FROM shops WHERE id::text = p_new_shop_id;

  -- Audit log
  INSERT INTO activity_logs
    (actor_id, action, target_type, target_id, target_label, details)
  VALUES (v_caller, 'shop.partner_promotion_reverted', 'stock_location',
          v_old_loc_id, v_shop.name,
          jsonb_build_object(
            'reverted_shop_id', p_new_shop_id,
            'restored_location_id', v_old_loc_id));

  RETURN v_old_loc_id;
END;
$fn$;

REVOKE ALL ON FUNCTION public.rollback_convert_partner(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rollback_convert_partner(text) TO authenticated;

-- ════════════════════════════════════════════════════════════════════════════
-- Mode d'emploi pour convertir "Flash Livraison Douala"
-- ════════════════════════════════════════════════════════════════════════════
--
-- 1. Récupère les ids nécessaires :
--
--    SELECT id, name, type FROM stock_locations
--     WHERE name ILIKE '%flash%' AND type = 'partner';
--    -- → note l'id, exemple : '01HXXXXXX'
--
--    SELECT id, name FROM shops WHERE name ILIKE '%mr original%';
--    -- → note l'id de Mr Original Base
--
--    SELECT user_id FROM shop_memberships
--     WHERE shop_id::text = '<base_id>' AND role = 'admin';
--    -- → note l'user_id de l'admin (s'il y en a un)
--
-- 2. Lance la conversion :
--
--    SELECT convert_partner_to_depot(
--      p_location_id    => '<location_id>',
--      p_parent_shop_id => '<base_shop_id>',
--      p_new_shop_name  => 'Flash Livraison Douala',  -- ou NULL pour défaut
--      p_admin_user_id  => '<admin_user_id>'          -- ou NULL si aucun
--    );
--    -- → retourne le NEW shop id
--
-- 3. Vérifie :
--
--    SELECT id, name, kind, parent_shop_id FROM shops
--     WHERE kind = 'partner_depot';
--    -- → la nouvelle boutique apparaît
--
--    SELECT * FROM stock_locations WHERE shop_id::text = '<new_shop_id>';
--    -- → la stock_location type='shop' a été créée
--
--    SELECT count(*), sum(stock_available) FROM stock_levels
--     WHERE location_id = '<new_loc_id>';
--    -- → les stocks ont été migrés
--
-- 4. En cas de souci, rollback immédiat :
--
--    SELECT rollback_convert_partner('<new_shop_id>');
--
-- ════════════════════════════════════════════════════════════════════════════
