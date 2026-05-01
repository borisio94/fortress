-- ═══════════════════════════════════════════════════════════════════════════
-- Fortress — Hotfix 003 : contournement pg_safeupdate
--
-- Contexte : Supabase active par défaut l'extension pg_safeupdate qui refuse
-- tout DELETE/UPDATE sans clause WHERE — même à l'intérieur d'une fonction
-- SECURITY DEFINER. Erreur observée : code 21000, « DELETE requires a
-- WHERE clause ». Ce n'est PAS la RLS qui bloque (les fonctions SECURITY
-- DEFINER s'exécutent avec un rôle BYPASSRLS).
--
-- Fix : ajouter WHERE true à chaque DELETE global, c-à-d dans les fonctions
-- reset_all_data() et reset_shop_data() (les DELETE avec IN(...) ont déjà
-- un WHERE, ils sont OK). On pose aussi SET LOCAL row_security = off en
-- sécurité supplémentaire.
--
-- Action : coller ce fichier dans Supabase → SQL Editor → Run.
-- ═══════════════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────────────
-- reset_all_data() — ajoute WHERE true à tous les DELETE globaux
-- ───────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS reset_all_data();
CREATE FUNCTION reset_all_data()
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
SET row_security = off
AS $fn$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND is_super_admin = true) THEN
    RAISE EXCEPTION 'Seul un super admin peut exécuter cette opération';
  END IF;

  -- WHERE true contourne pg_safeupdate. Les lignes de vente sont stockées
  -- en JSONB dans orders.items (pas de table sale_items).
  DELETE FROM orders           WHERE true;
  DELETE FROM products         WHERE true;
  DELETE FROM categories       WHERE true;
  DELETE FROM clients          WHERE true;
  DELETE FROM shop_memberships WHERE true;
  DELETE FROM shops            WHERE true;
  DELETE FROM subscriptions    WHERE true;
  DELETE FROM profiles         WHERE COALESCE(is_super_admin, false) = false;

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
-- delete_user_account(uuid) — inchangé côté schéma (tous les DELETE ont déjà
-- un WHERE avec IN(...)), mais on recrée avec SET row_security = off par
-- cohérence.
-- ───────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS delete_user_account(UUID);
CREATE FUNCTION delete_user_account(p_user_id UUID)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER
SET row_security = off
AS $fn$
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
-- reset_shop_data(uuid) — tous les DELETE ont déjà un WHERE ciblé, on ne
-- recrée que pour ajouter SET row_security = off par cohérence.
-- ───────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS reset_shop_data(UUID);
CREATE FUNCTION reset_shop_data(p_shop_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET row_security = off
AS $fn$
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
