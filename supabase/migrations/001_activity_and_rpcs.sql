-- ═══════════════════════════════════════════════════════════════════════════
-- Fortress — Migration 001 : activity_logs + RPCs métier
-- Exécutée automatiquement par SupabaseMigrations au démarrage via exec_sql.
-- Les chunks (séparés par -- @@CHUNK@@) sont envoyés individuellement.
-- ═══════════════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────────────
-- TABLE activity_logs  (idempotent : CREATE IF NOT EXISTS + ALTER ADD COLUMN)
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS activity_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_id     UUID,
  actor_email  TEXT,
  action       TEXT NOT NULL,
  target_type  TEXT,
  target_id    TEXT,
  target_label TEXT,
  shop_id      UUID,
  details      JSONB,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Colonnes ajoutées si migration depuis P0 (metadata → details)
ALTER TABLE activity_logs ADD COLUMN IF NOT EXISTS actor_email  TEXT;
ALTER TABLE activity_logs ADD COLUMN IF NOT EXISTS target_label TEXT;
ALTER TABLE activity_logs ADD COLUMN IF NOT EXISTS shop_id      UUID;
ALTER TABLE activity_logs ADD COLUMN IF NOT EXISTS details      JSONB;

-- Renommer metadata en details si version antérieure
DO $mig$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema='public' AND table_name='activity_logs'
               AND column_name='metadata') THEN
    BEGIN
      ALTER TABLE activity_logs RENAME COLUMN metadata TO details;
    EXCEPTION WHEN duplicate_column THEN
      -- details existe déjà : ignorer
      NULL;
    END;
  END IF;
END $mig$;

-- target_id en TEXT (accepte non-UUID p.ex. "order_1234567")
DO $mig$
BEGIN
  IF (SELECT data_type FROM information_schema.columns
      WHERE table_schema='public' AND table_name='activity_logs'
        AND column_name='target_id') = 'uuid' THEN
    ALTER TABLE activity_logs ALTER COLUMN target_id TYPE TEXT USING target_id::text;
  END IF;
END $mig$;

CREATE INDEX IF NOT EXISTS activity_logs_actor_idx   ON activity_logs(actor_id);
CREATE INDEX IF NOT EXISTS activity_logs_action_idx  ON activity_logs(action);
CREATE INDEX IF NOT EXISTS activity_logs_shop_idx    ON activity_logs(shop_id);
CREATE INDEX IF NOT EXISTS activity_logs_created_idx ON activity_logs(created_at DESC);

-- @@CHUNK@@

-- ───────────────────────────────────────────────────────────────────────────
-- RLS + policies
-- ───────────────────────────────────────────────────────────────────────────
ALTER TABLE activity_logs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS activity_logs_super_admin_read    ON activity_logs;
DROP POLICY IF EXISTS activity_logs_authenticated_write ON activity_logs;
CREATE POLICY activity_logs_super_admin_read ON activity_logs
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND is_super_admin = true)
  );
CREATE POLICY activity_logs_authenticated_write ON activity_logs
  FOR INSERT WITH CHECK (auth.uid() IS NOT NULL);

-- @@CHUNK@@

-- ───────────────────────────────────────────────────────────────────────────
-- RPC delete_user_account(p_user_id uuid) RETURNS uuid
-- Super admin OU l'utilisateur lui-même peut supprimer son compte.
-- Purge en cascade + log activité. Retourne l'id supprimé.
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

  -- Les lignes de vente sont stockées en JSONB dans orders.items (pas de table séparée)
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

  -- auth.users en dernier (supprime automatiquement la session)
  BEGIN
    DELETE FROM auth.users WHERE id = p_user_id;
  EXCEPTION WHEN insufficient_privilege THEN
    -- Sur projets où auth.users n'est pas accessible, profile suffit
    NULL;
  END;

  RETURN p_user_id;
END $fn$;
REVOKE ALL ON FUNCTION delete_user_account(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION delete_user_account(UUID) TO authenticated;

-- @@CHUNK@@

-- ───────────────────────────────────────────────────────────────────────────
-- RPC reset_shop_data(p_shop_id uuid) RETURNS jsonb
-- Propriétaire OU super admin. Renvoie les compteurs supprimés.
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

  -- Les lignes de vente sont stockées en JSONB dans orders.items
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

-- @@CHUNK@@

-- ───────────────────────────────────────────────────────────────────────────
-- RPC get_user_summary(p_user_id uuid) RETURNS jsonb
-- Utilisé par la confirmation de suppression de compte.
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
  -- Lecture autorisée à soi-même ou aux super admins
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

-- @@CHUNK@@

-- ───────────────────────────────────────────────────────────────────────────
-- RPC reset_all_data() RETURNS void
-- Super admin uniquement. Vide toutes les tables métier sauf :
--   - profiles super admin
--   - plans
--   - auth.users des super admins
--   - activity_logs (préservé pour audit)
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

  -- WHERE true contourne pg_safeupdate (qui refuse DELETE sans WHERE).
  -- Les lignes de vente sont en JSONB dans orders.items.
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

-- @@CHUNK@@

-- ───────────────────────────────────────────────────────────────────────────
-- pending_invitations — système d'invitation par email
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS pending_invitations (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id    TEXT NOT NULL REFERENCES shops(id) ON DELETE CASCADE,
  email      TEXT NOT NULL,
  role       TEXT NOT NULL DEFAULT 'cashier'
             CHECK (role IN ('admin','manager','cashier')),
  token      TEXT NOT NULL UNIQUE,
  invited_by UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL DEFAULT (now() + interval '7 days'),
  UNIQUE (shop_id, email)
);
CREATE INDEX IF NOT EXISTS pending_invitations_token_idx   ON pending_invitations(token);
CREATE INDEX IF NOT EXISTS pending_invitations_shop_idx    ON pending_invitations(shop_id);
CREATE INDEX IF NOT EXISTS pending_invitations_email_idx   ON pending_invitations(lower(email));
CREATE INDEX IF NOT EXISTS pending_invitations_expires_idx ON pending_invitations(expires_at);

ALTER TABLE pending_invitations ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS pending_invitations_shop_admin ON pending_invitations;
CREATE POLICY pending_invitations_shop_admin ON pending_invitations FOR ALL USING (
  shop_id IN (SELECT shop_id FROM shop_memberships
              WHERE user_id = (auth.uid())::text AND role = 'admin'));
DROP POLICY IF EXISTS pending_invitations_self_read ON pending_invitations;
CREATE POLICY pending_invitations_self_read ON pending_invitations FOR SELECT USING (
  lower(email) = lower(auth.jwt() ->> 'email'));

-- @@CHUNK@@

DROP FUNCTION IF EXISTS create_shop_invitation(TEXT, TEXT, TEXT);
CREATE FUNCTION create_shop_invitation(
  p_shop_id TEXT, p_email TEXT, p_role TEXT DEFAULT 'cashier'
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET row_security = off AS $fn$
DECLARE
  v_token TEXT; v_id UUID; v_caller_role TEXT; v_is_sa BOOLEAN;
  v_email_norm TEXT := lower(trim(p_email));
BEGIN
  SELECT role INTO v_caller_role FROM shop_memberships
    WHERE shop_id = p_shop_id AND user_id = (auth.uid())::text LIMIT 1;
  SELECT COALESCE(is_super_admin, false) INTO v_is_sa
    FROM profiles WHERE id = auth.uid();
  IF v_caller_role IS DISTINCT FROM 'admin' AND NOT COALESCE(v_is_sa, false) THEN
    RAISE EXCEPTION 'Non autorisé : admin de la boutique requis';
  END IF;
  IF EXISTS (SELECT 1 FROM profiles p JOIN shop_memberships m ON m.user_id = p.id::text
             WHERE lower(p.email) = v_email_norm AND m.shop_id = p_shop_id) THEN
    RAISE EXCEPTION 'Cet utilisateur est déjà membre de la boutique';
  END IF;
  v_token := replace(replace(replace(encode(gen_random_bytes(24), 'base64'),
                             '/', '_'), '+', '-'), '=', '');
  INSERT INTO pending_invitations (shop_id, email, role, token, invited_by)
  VALUES (p_shop_id, v_email_norm, p_role, v_token, auth.uid())
  ON CONFLICT (shop_id, email) DO UPDATE
    SET token = EXCLUDED.token, role = EXCLUDED.role,
        invited_by = EXCLUDED.invited_by,
        created_at = now(), expires_at = now() + interval '7 days'
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('id', v_id, 'token', v_token);
END $fn$;
REVOKE ALL ON FUNCTION create_shop_invitation(TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION create_shop_invitation(TEXT, TEXT, TEXT) TO authenticated;

DROP FUNCTION IF EXISTS get_invitation_info(TEXT);
CREATE FUNCTION get_invitation_info(p_token TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE v_inv pending_invitations%ROWTYPE; v_shop_name TEXT;
BEGIN
  SELECT * INTO v_inv FROM pending_invitations WHERE token = p_token;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('valid', false, 'reason', 'not_found');
  END IF;
  IF v_inv.expires_at < now() THEN
    RETURN jsonb_build_object('valid', false, 'reason', 'expired');
  END IF;
  SELECT name INTO v_shop_name FROM shops WHERE id = v_inv.shop_id;
  RETURN jsonb_build_object('valid', true, 'email', v_inv.email,
    'role', v_inv.role, 'shop_id', v_inv.shop_id, 'shop_name', v_shop_name,
    'expires_at', v_inv.expires_at);
END $fn$;
REVOKE ALL ON FUNCTION get_invitation_info(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_invitation_info(TEXT) TO anon, authenticated;

DROP FUNCTION IF EXISTS accept_shop_invitation(TEXT);
CREATE FUNCTION accept_shop_invitation(p_token TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET row_security = off AS $fn$
DECLARE v_inv pending_invitations%ROWTYPE; v_user_id TEXT; v_user_email TEXT;
BEGIN
  SELECT * INTO v_inv FROM pending_invitations WHERE token = p_token;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invitation introuvable'; END IF;
  IF v_inv.expires_at < now() THEN RAISE EXCEPTION 'Invitation expirée'; END IF;
  v_user_id := (auth.uid())::text;
  v_user_email := lower(auth.jwt() ->> 'email');
  IF v_user_id IS NULL OR v_user_email IS NULL THEN
    RAISE EXCEPTION 'Connexion requise';
  END IF;
  IF lower(v_inv.email) <> v_user_email THEN
    RAISE EXCEPTION 'Cette invitation a été envoyée à une autre adresse';
  END IF;
  IF EXISTS (SELECT 1 FROM shop_memberships WHERE shop_id = v_inv.shop_id AND user_id = v_user_id) THEN
    UPDATE shop_memberships SET role = v_inv.role
      WHERE shop_id = v_inv.shop_id AND user_id = v_user_id;
  ELSE
    INSERT INTO shop_memberships (shop_id, user_id, role)
    VALUES (v_inv.shop_id, v_user_id, v_inv.role);
  END IF;
  DELETE FROM pending_invitations WHERE id = v_inv.id;
  INSERT INTO activity_logs (actor_id, actor_email, action, target_type, target_id, shop_id, details)
  VALUES (auth.uid(), v_user_email, 'invitation_accepted', 'shop',
          v_inv.shop_id, v_inv.shop_id,
          jsonb_build_object('role', v_inv.role));
  RETURN jsonb_build_object('shop_id', v_inv.shop_id, 'role', v_inv.role);
END $fn$;
REVOKE ALL ON FUNCTION accept_shop_invitation(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION accept_shop_invitation(TEXT) TO authenticated;

-- @@CHUNK@@

-- ───────────────────────────────────────────────────────────────────────────
-- super_admin_whitelist — élévation automatique des SA par email
-- ⚠️ Après l'installation, ajouter manuellement un email dans le SQL Editor :
--     INSERT INTO super_admin_whitelist (email, note)
--     VALUES ('ton.email@exemple.com', 'Fondateur')
--     ON CONFLICT (email) DO NOTHING;
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS super_admin_whitelist (
  email    TEXT PRIMARY KEY,
  added_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  note     TEXT
);
ALTER TABLE super_admin_whitelist ENABLE ROW LEVEL SECURITY;
-- Aucune policy → table invisible via PostgREST, accès SQL Editor uniquement

CREATE OR REPLACE FUNCTION apply_super_admin_whitelist()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $fn$
BEGIN
  IF NEW.email IS NOT NULL AND EXISTS (
    SELECT 1 FROM super_admin_whitelist
    WHERE lower(email) = lower(NEW.email)
  ) THEN
    NEW.is_super_admin := true;
    INSERT INTO activity_logs (actor_id, actor_email, action, target_type, target_id, details)
    VALUES (NEW.id, NEW.email, 'super_admin_granted', 'user',
            NEW.id::text, jsonb_build_object('via', 'whitelist'));
  END IF;
  RETURN NEW;
END $fn$;

DROP TRIGGER IF EXISTS trg_super_admin_whitelist ON profiles;
CREATE TRIGGER trg_super_admin_whitelist
  BEFORE INSERT OR UPDATE OF email ON profiles
  FOR EACH ROW EXECUTE FUNCTION apply_super_admin_whitelist();

-- Rétro-application pour les profiles existants
UPDATE profiles p
   SET is_super_admin = true
  FROM super_admin_whitelist w
 WHERE lower(p.email) = lower(w.email)
   AND COALESCE(p.is_super_admin, false) = false;
