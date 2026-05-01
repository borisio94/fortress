-- ═══════════════════════════════════════════════════════════════════════════
-- Fortress — Hotfix 007 : autoriser les admins de boutique à réinitialiser
--
-- Contexte : reset_shop_data() n'autorisait que le propriétaire (owner_id)
-- ou un super_admin. Un membre avec le rôle 'admin' dans shop_memberships
-- ne pouvait pas réinitialiser sa boutique depuis la page Paramètres.
--
-- Fix : - autoriser les admins de boutique (shop_memberships.role = 'admin')
--       - caster systématiquement en TEXT pour éviter « text = uuid »
--         (les tables métier créées via le Dashboard utilisent text, pas uuid)
--
-- Action : coller dans Supabase → SQL Editor → Run.
-- ═══════════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS reset_shop_data(UUID);
CREATE FUNCTION reset_shop_data(p_shop_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET row_security = off
AS $fn$
DECLARE
  v_sid     TEXT := p_shop_id::text;
  v_uid     TEXT := auth.uid()::text;
  v_owner   TEXT;
  v_name    TEXT;
  v_orders  INT;
  v_products INT;
  v_cats    INT;
  v_clients INT;
BEGIN
  -- Récupérer owner_id et name en castant pour comparaison text
  SELECT owner_id::text, name INTO v_owner, v_name
    FROM shops WHERE id::text = v_sid;

  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'Boutique introuvable';
  END IF;

  -- Autoriser : propriétaire, super_admin, OU admin de la boutique
  IF v_owner <> v_uid
     AND NOT EXISTS (
       SELECT 1 FROM profiles
       WHERE id::text = v_uid AND is_super_admin = true
     )
     AND NOT EXISTS (
       SELECT 1 FROM shop_memberships
       WHERE shop_id::text = v_sid
         AND user_id::text = v_uid
         AND role = 'admin'
     )
  THEN
    RAISE EXCEPTION 'Non autorisé : propriétaire, super admin ou admin boutique requis';
  END IF;

  -- Supprimer les données métier (comparaisons text = text)
  WITH deleted AS (DELETE FROM orders     WHERE shop_id::text  = v_sid RETURNING 1)
    SELECT count(*) INTO v_orders   FROM deleted;
  WITH deleted AS (DELETE FROM products   WHERE store_id::text = v_sid RETURNING 1)
    SELECT count(*) INTO v_products FROM deleted;
  WITH deleted AS (DELETE FROM categories WHERE shop_id::text  = v_sid RETURNING 1)
    SELECT count(*) INTO v_cats     FROM deleted;
  WITH deleted AS (DELETE FROM clients    WHERE store_id::text = v_sid RETURNING 1)
    SELECT count(*) INTO v_clients  FROM deleted;

  -- Log
  INSERT INTO activity_logs (actor_id, actor_email, action, target_type, target_id, target_label, shop_id, details)
  VALUES (auth.uid(),
          (SELECT email FROM auth.users WHERE id::text = v_uid),
          'shop_reset', 'shop', v_sid, v_name, p_shop_id,
          jsonb_build_object(
              'orders',   v_orders,
              'products', v_products,
              'categories', v_cats,
              'clients',  v_clients));

  RETURN jsonb_build_object(
    'orders',     v_orders,
    'products',   v_products,
    'categories', v_cats,
    'clients',    v_clients
  );
END $fn$;
REVOKE ALL ON FUNCTION reset_shop_data(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION reset_shop_data(UUID) TO authenticated;
