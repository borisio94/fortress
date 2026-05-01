-- ═══════════════════════════════════════════════════════════════════════════
-- Fortress — Hotfix 002 : correction des noms de tables
--
-- Contexte : la migration 001 référençait une table `sale_items` inexistante
-- (les lignes de vente sont stockées en JSONB dans `orders.items`) et utilisait
-- `clients.shop_id` au lieu de `clients.store_id`.
--
-- Action : coller le contenu complet de ce fichier dans
--          Supabase → SQL Editor → Run.
--
-- Après exécution, les RPCs reset_all_data(), delete_user_account() et
-- reset_shop_data() seront recréées avec les bons noms de tables/colonnes.
-- ═══════════════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────────────
-- 1. reset_all_data() — retire DELETE FROM sale_items
-- ───────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS reset_all_data();
CREATE FUNCTION reset_all_data()
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $fn$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND is_super_admin = true) THEN
    RAISE EXCEPTION 'Seul un super admin peut exécuter cette opération';
  END IF;

  -- Les lignes de vente sont stockées en JSONB dans orders.items
  DELETE FROM orders;
  DELETE FROM products;
  DELETE FROM categories;
  DELETE FROM clients;
  DELETE FROM shop_memberships;
  DELETE FROM shops;
  DELETE FROM subscriptions;
  DELETE FROM profiles WHERE COALESCE(is_super_admin, false) = false;

  BEGIN
    DELETE FROM auth.users
      WHERE id NOT IN (SELECT id FROM profiles WHERE is_super_admin = true);
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  INSERT INTO activity_logs (actor_id, actor_email, action, target_type, details)
  VALUES (auth.uid(),
          (SELECT email FROM auth.users WHERE id = auth.uid()),
          'platform_reset', 'platform',
          jsonb_build_object('at', now()));
END $fn$;
REVOKE ALL ON FUNCTION reset_all_data() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION reset_all_data() TO authenticated;

-- ───────────────────────────────────────────────────────────────────────────
-- 2. delete_user_account(uuid) — retire sale_items + clients.shop_id → store_id
-- ───────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS delete_user_account(UUID);
CREATE FUNCTION delete_user_account(p_user_id UUID)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE
  v_is_sa BOOLEAN;
  v_email TEXT;
  v_name  TEXT;
BEGIN
  SELECT COALESCE(is_super_admin, false) INTO v_is_sa
    FROM profiles WHERE id = auth.uid();

  IF NOT v_is_sa AND p_user_id <> auth.uid() THEN
    RAISE EXCEPTION 'Non autorisé : vous ne pouvez supprimer que votre propre compte';
  END IF;

  SELECT email, name INTO v_email, v_name FROM profiles WHERE id = p_user_id;

  -- Les lignes de vente sont en JSONB dans orders.items (pas de table séparée)
  DELETE FROM orders          WHERE shop_id  IN (SELECT id FROM shops WHERE owner_id = p_user_id);
  DELETE FROM products        WHERE store_id IN (SELECT id FROM shops WHERE owner_id = p_user_id);
  DELETE FROM categories      WHERE shop_id  IN (SELECT id FROM shops WHERE owner_id = p_user_id);
  DELETE FROM clients         WHERE store_id IN (SELECT id FROM shops WHERE owner_id = p_user_id);
  DELETE FROM shop_memberships WHERE shop_id IN (SELECT id FROM shops WHERE owner_id = p_user_id);
  DELETE FROM shops           WHERE owner_id = p_user_id;
  DELETE FROM subscriptions   WHERE user_id = p_user_id;
  DELETE FROM shop_memberships WHERE user_id = p_user_id;
  DELETE FROM profiles        WHERE id = p_user_id;

  INSERT INTO activity_logs (actor_id, actor_email, action, target_type, target_id, target_label, details)
  VALUES (auth.uid(),
          (SELECT email FROM auth.users WHERE id = auth.uid()),
          CASE WHEN auth.uid() = p_user_id THEN 'account_deleted' ELSE 'user_deleted' END,
          'user', p_user_id::text, v_name,
          jsonb_build_object('email', v_email, 'by_super_admin', v_is_sa));

  BEGIN
    DELETE FROM auth.users WHERE id = p_user_id;
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  RETURN p_user_id;
END $fn$;
REVOKE ALL ON FUNCTION delete_user_account(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION delete_user_account(UUID) TO authenticated;

-- ───────────────────────────────────────────────────────────────────────────
-- 3. reset_shop_data(uuid) — retire sale_items + clients.shop_id → store_id
-- ───────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS reset_shop_data(UUID);
CREATE FUNCTION reset_shop_data(p_shop_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE
  v_owner UUID;
  v_name  TEXT;
  v_orders INT; v_products INT; v_cats INT; v_clients INT;
BEGIN
  SELECT owner_id, name INTO v_owner, v_name FROM shops WHERE id = p_shop_id;
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'Boutique introuvable';
  END IF;
  IF v_owner <> auth.uid() AND NOT EXISTS (
    SELECT 1 FROM profiles WHERE id = auth.uid() AND is_super_admin = true
  ) THEN
    RAISE EXCEPTION 'Non autorisé : propriétaire ou super admin requis';
  END IF;

  WITH deleted AS (DELETE FROM orders     WHERE shop_id  = p_shop_id RETURNING 1)
    SELECT count(*) INTO v_orders   FROM deleted;
  WITH deleted AS (DELETE FROM products   WHERE store_id = p_shop_id RETURNING 1)
    SELECT count(*) INTO v_products FROM deleted;
  WITH deleted AS (DELETE FROM categories WHERE shop_id  = p_shop_id RETURNING 1)
    SELECT count(*) INTO v_cats     FROM deleted;
  WITH deleted AS (DELETE FROM clients    WHERE store_id = p_shop_id RETURNING 1)
    SELECT count(*) INTO v_clients  FROM deleted;

  INSERT INTO activity_logs (actor_id, actor_email, action, target_type, target_id, target_label, shop_id, details)
  VALUES (auth.uid(),
          (SELECT email FROM auth.users WHERE id = auth.uid()),
          'shop_reset', 'shop', p_shop_id::text, v_name, p_shop_id,
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

-- ───────────────────────────────────────────────────────────────────────────
-- 4. get_user_summary(uuid) — corrige clients.shop_id → store_id
-- ───────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS get_user_summary(UUID);
CREATE FUNCTION get_user_summary(p_user_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE
  v_shops    INT;
  v_products INT;
  v_sales    INT;
  v_clients  INT;
BEGIN
  IF auth.uid() IS DISTINCT FROM p_user_id AND NOT EXISTS (
    SELECT 1 FROM profiles WHERE id = auth.uid() AND is_super_admin = true
  ) THEN
    RAISE EXCEPTION 'Non autorisé';
  END IF;

  SELECT count(*) INTO v_shops    FROM shops    WHERE owner_id = p_user_id;
  SELECT count(*) INTO v_products FROM products WHERE store_id IN (SELECT id FROM shops WHERE owner_id = p_user_id);
  SELECT count(*) INTO v_sales    FROM orders   WHERE shop_id  IN (SELECT id FROM shops WHERE owner_id = p_user_id);
  SELECT count(*) INTO v_clients  FROM clients  WHERE store_id IN (SELECT id FROM shops WHERE owner_id = p_user_id);

  RETURN jsonb_build_object(
    'shops_count',    v_shops,
    'products_count', v_products,
    'sales_count',    v_sales,
    'clients_count',  v_clients
  );
END $fn$;
REVOKE ALL ON FUNCTION get_user_summary(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_user_summary(UUID) TO authenticated;
