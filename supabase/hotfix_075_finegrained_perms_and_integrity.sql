-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_075_finegrained_perms_and_integrity.sql
--
-- 🚨 HIGH — défense en profondeur : ferme l'écart entre les permissions
-- fines appliquées par l'UI (AppPermissions côté Flutter) et la RLS, qui
-- n'exigeait jusqu'ici que « membre du shop » pour écrire sur products /
-- clients. Un membre role='user' pouvait, via l'API REST directe,
-- supprimer le catalogue ou réécrire les prix malgré l'UI qui l'interdit.
--
-- S'appuie sur le helper EXISTANT public._user_has_permission(shop, perm)
-- (hotfix_039) qui résout déjà : owner/super-admin = bypass, sinon
-- grants/denies JSONB puis fallback rôle. Mêmes clés que côté Dart
-- (employee_permission.dart) : inventory.write, inventory.delete,
-- crm.delete.
--
-- ⚠️ PORTÉE VOLONTAIREMENT ÉTROITE — on NE gate PAS l'UPDATE générique de
--    `products` : le flux caissier décrémente stock_qty via UPDATE, un
--    gate large casserait les ventes des role='user'. On gate uniquement
--    les opérations JAMAIS issues d'une vente :
--      • products : INSERT (création), DELETE, et UPDATE qui change
--        price_sell_pos (réécriture de prix).
--      • clients  : DELETE.
--    INSERT/UPDATE clients reste libre (création client à l'encaissement
--    par un caissier = légitime).
--
-- Plus : CHECK d'intégrité financière en NOT VALID (n'échoue donc PAS sur
-- les lignes existantes, mais bloque toute nouvelle valeur aberrante).
--
-- 100 % idempotent. Réexécutable.
--
-- ════════════════════════════════════════════════════════════════════════════
-- ⚠️ À TESTER hors heures de pointe (ou sur copie) AVANT exploitation :
--    ce hotfix modifie le comportement des écritures. Smoke tests fournis
--    en bas de fichier.
-- ════════════════════════════════════════════════════════════════════════════


-- ── 1. Garde-fou mutations `products` ────────────────────────────────────
DROP TRIGGER  IF EXISTS trg_enforce_product_mutation_perms ON products;
DROP FUNCTION IF EXISTS public.enforce_product_mutation_perms() CASCADE;

CREATE OR REPLACE FUNCTION public.enforce_product_mutation_perms()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $enforce$
BEGIN
  -- DELETE : require inventory.delete (suppression catalogue).
  IF TG_OP = 'DELETE' THEN
    IF NOT public._user_has_permission(OLD.store_id::text, 'inventory.delete') THEN
      RAISE EXCEPTION
        'Action interdite : suppression de produit requiert la '
        'permission inventory.delete'
        USING ERRCODE = '42501';
    END IF;
    RETURN OLD;
  END IF;

  -- INSERT : require inventory.write (création produit ≠ vente).
  IF TG_OP = 'INSERT' THEN
    IF NOT public._user_has_permission(NEW.store_id::text, 'inventory.write') THEN
      RAISE EXCEPTION
        'Action interdite : création de produit requiert la '
        'permission inventory.write'
        USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
  END IF;

  -- UPDATE : on ne gate QUE la réécriture du prix de vente. Une vente ne
  -- touche jamais price_sell_pos (elle bouge stock_qty / promo_*), donc
  -- les caissiers ne sont pas impactés.
  IF TG_OP = 'UPDATE'
     AND COALESCE(NEW.price_sell_pos, -1) IS DISTINCT FROM
         COALESCE(OLD.price_sell_pos, -1) THEN
    IF NOT public._user_has_permission(NEW.store_id::text, 'inventory.write') THEN
      RAISE EXCEPTION
        'Action interdite : modification du prix de vente requiert '
        'la permission inventory.write'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  RETURN NEW;
END;
$enforce$;

CREATE TRIGGER trg_enforce_product_mutation_perms
BEFORE INSERT OR UPDATE OR DELETE ON products
FOR EACH ROW EXECUTE FUNCTION public.enforce_product_mutation_perms();


-- ── 2. Garde-fou suppression `clients` ───────────────────────────────────
DROP TRIGGER  IF EXISTS trg_enforce_client_delete_perms ON clients;
DROP FUNCTION IF EXISTS public.enforce_client_delete_perms() CASCADE;

CREATE OR REPLACE FUNCTION public.enforce_client_delete_perms()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $enforce$
BEGIN
  IF NOT public._user_has_permission(OLD.store_id::text, 'crm.delete') THEN
    RAISE EXCEPTION
      'Action interdite : suppression de client requiert la '
      'permission crm.delete'
      USING ERRCODE = '42501';
  END IF;
  RETURN OLD;
END;
$enforce$;

CREATE TRIGGER trg_enforce_client_delete_perms
BEFORE DELETE ON clients
FOR EACH ROW EXECUTE FUNCTION public.enforce_client_delete_perms();


-- ── 3. Intégrité financière (CHECK NOT VALID) ────────────────────────────
-- NOT VALID : Postgres n'exécute PAS la validation sur les lignes
-- existantes (le script ne peut donc pas échouer sur d'anciennes données
-- aberrantes), mais la contrainte est bien appliquée à toute écriture
-- future. Idempotent : on ne crée que si absente.

DO $integrity$
BEGIN
  -- products.price_sell_pos >= 0
  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema='public' AND table_name='products'
                AND column_name='price_sell_pos')
     AND NOT EXISTS (SELECT 1 FROM pg_constraint
                      WHERE conname = 'products_price_sell_pos_nonneg_chk') THEN
    ALTER TABLE products
      ADD CONSTRAINT products_price_sell_pos_nonneg_chk
      CHECK (price_sell_pos IS NULL OR price_sell_pos >= 0) NOT VALID;
  END IF;

  -- orders.discount_amount >= 0
  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema='public' AND table_name='orders'
                AND column_name='discount_amount')
     AND NOT EXISTS (SELECT 1 FROM pg_constraint
                      WHERE conname = 'orders_discount_nonneg_chk') THEN
    ALTER TABLE orders
      ADD CONSTRAINT orders_discount_nonneg_chk
      CHECK (discount_amount IS NULL OR discount_amount >= 0) NOT VALID;
  END IF;
END
$integrity$;


-- ── 4. Vérifications après application (LECTURE SEULE) ───────────────────
-- 1) Les 2 triggers + 2 contraintes existent :
--    SELECT tgname FROM pg_trigger
--     WHERE tgname IN ('trg_enforce_product_mutation_perms',
--                      'trg_enforce_client_delete_perms');
--    SELECT conname, convalidated FROM pg_constraint
--     WHERE conname IN ('products_price_sell_pos_nonneg_chk',
--                       'orders_discount_nonneg_chk');
--
-- 2) Smoke test (session JWT d'un caissier role='user' SANS inventory.*) :
--    -- doit RÉUSSIR (vente : décrément stock, prix inchangé) :
--      UPDATE products SET stock_qty = stock_qty - 1 WHERE id = '<id>';
--    -- doit ÉCHOUER 42501 (réécriture prix) :
--      UPDATE products SET price_sell_pos = 1 WHERE id = '<id>';
--    -- doit ÉCHOUER 42501 (suppression) :
--      DELETE FROM products WHERE id = '<id>';
--    -- doit ÉCHOUER 42501 :
--      DELETE FROM clients WHERE id = '<id>';
--
-- 3) Avec un owner / admin : toutes ces opérations doivent RÉUSSIR
--    (bypass via _user_has_permission).
--
-- Rollback éventuel :
--   DROP TRIGGER trg_enforce_product_mutation_perms ON products;
--   DROP TRIGGER trg_enforce_client_delete_perms ON clients;
--   ALTER TABLE products DROP CONSTRAINT products_price_sell_pos_nonneg_chk;
--   ALTER TABLE orders   DROP CONSTRAINT orders_discount_nonneg_chk;
-- ════════════════════════════════════════════════════════════════════════════
