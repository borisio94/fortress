-- ═══════════════════════════════════════════════════════════════════════════
-- Fortress — Hotfix 004 : système d'invitations par email
--
-- Crée la table pending_invitations + RLS + 3 RPCs :
--   create_shop_invitation   — admin génère un token pour une adresse
--   get_invitation_info      — page /accept-invite lit les métadonnées
--   accept_shop_invitation   — invité consomme le token → crée membership
--
-- Expiration : 7 jours par défaut. Les requêtes filtrent sur expires_at > now().
-- Un pg_cron pourrait nettoyer les expirées si l'extension est activée.
--
-- Action : coller dans Supabase → SQL Editor → Run.
-- ═══════════════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────────────
-- TABLE pending_invitations
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

-- ───────────────────────────────────────────────────────────────────────────
-- RLS
-- ───────────────────────────────────────────────────────────────────────────
ALTER TABLE pending_invitations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS pending_invitations_shop_admin ON pending_invitations;
CREATE POLICY pending_invitations_shop_admin ON pending_invitations FOR ALL USING (
  shop_id IN (
    SELECT shop_id FROM shop_memberships
    WHERE user_id = (auth.uid())::text AND role = 'admin'
  )
);

-- L'invité peut lire son invitation (filtre par email du JWT)
DROP POLICY IF EXISTS pending_invitations_self_read ON pending_invitations;
CREATE POLICY pending_invitations_self_read ON pending_invitations FOR SELECT USING (
  lower(email) = lower(auth.jwt() ->> 'email')
);

-- ───────────────────────────────────────────────────────────────────────────
-- RPC create_shop_invitation — admin uniquement, génère le token
-- ───────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS create_shop_invitation(TEXT, TEXT, TEXT);
CREATE FUNCTION create_shop_invitation(
  p_shop_id TEXT,
  p_email   TEXT,
  p_role    TEXT DEFAULT 'cashier'
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET row_security = off
AS $fn$
DECLARE
  v_token       TEXT;
  v_id          UUID;
  v_caller_role TEXT;
  v_is_sa       BOOLEAN;
  v_email_norm  TEXT := lower(trim(p_email));
BEGIN
  -- Permissions : admin de la boutique OU super admin
  SELECT role INTO v_caller_role FROM shop_memberships
    WHERE shop_id = p_shop_id AND user_id = (auth.uid())::text LIMIT 1;
  SELECT COALESCE(is_super_admin, false) INTO v_is_sa
    FROM profiles WHERE id = auth.uid();
  IF v_caller_role IS DISTINCT FROM 'admin' AND NOT COALESCE(v_is_sa, false) THEN
    RAISE EXCEPTION 'Non autorisé : admin de la boutique requis';
  END IF;

  -- Empêcher d'inviter un user déjà membre
  IF EXISTS (
    SELECT 1 FROM profiles p
      JOIN shop_memberships m ON m.user_id = p.id::text
    WHERE lower(p.email) = v_email_norm AND m.shop_id = p_shop_id
  ) THEN
    RAISE EXCEPTION 'Cet utilisateur est déjà membre de la boutique';
  END IF;

  v_token := replace(encode(gen_random_bytes(24), 'base64'), '/', '_');
  v_token := replace(v_token, '+', '-');
  v_token := replace(v_token, '=', '');

  INSERT INTO pending_invitations (shop_id, email, role, token, invited_by)
  VALUES (p_shop_id, v_email_norm, p_role, v_token, auth.uid())
  ON CONFLICT (shop_id, email) DO UPDATE
    SET token      = EXCLUDED.token,
        role       = EXCLUDED.role,
        invited_by = EXCLUDED.invited_by,
        created_at = now(),
        expires_at = now() + interval '7 days'
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('id', v_id, 'token', v_token);
END $fn$;
REVOKE ALL ON FUNCTION create_shop_invitation(TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION create_shop_invitation(TEXT, TEXT, TEXT) TO authenticated;

-- ───────────────────────────────────────────────────────────────────────────
-- RPC get_invitation_info — lecture publique par token (capability)
-- ───────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS get_invitation_info(TEXT);
CREATE FUNCTION get_invitation_info(p_token TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE
  v_inv       pending_invitations%ROWTYPE;
  v_shop_name TEXT;
BEGIN
  SELECT * INTO v_inv FROM pending_invitations WHERE token = p_token;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('valid', false, 'reason', 'not_found');
  END IF;
  IF v_inv.expires_at < now() THEN
    RETURN jsonb_build_object('valid', false, 'reason', 'expired');
  END IF;
  SELECT name INTO v_shop_name FROM shops WHERE id = v_inv.shop_id;
  RETURN jsonb_build_object(
    'valid',      true,
    'email',      v_inv.email,
    'role',       v_inv.role,
    'shop_id',    v_inv.shop_id,
    'shop_name',  v_shop_name,
    'expires_at', v_inv.expires_at
  );
END $fn$;
REVOKE ALL ON FUNCTION get_invitation_info(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_invitation_info(TEXT) TO anon, authenticated;

-- ───────────────────────────────────────────────────────────────────────────
-- RPC accept_shop_invitation — consomme le token, crée/maj membership
-- ───────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS accept_shop_invitation(TEXT);
CREATE FUNCTION accept_shop_invitation(p_token TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET row_security = off
AS $fn$
DECLARE
  v_inv        pending_invitations%ROWTYPE;
  v_user_id    TEXT;
  v_user_email TEXT;
BEGIN
  SELECT * INTO v_inv FROM pending_invitations WHERE token = p_token;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Invitation introuvable';
  END IF;
  IF v_inv.expires_at < now() THEN
    RAISE EXCEPTION 'Invitation expirée';
  END IF;

  v_user_id    := (auth.uid())::text;
  v_user_email := lower(auth.jwt() ->> 'email');
  IF v_user_id IS NULL OR v_user_email IS NULL THEN
    RAISE EXCEPTION 'Connexion requise';
  END IF;

  IF lower(v_inv.email) <> v_user_email THEN
    RAISE EXCEPTION 'Cette invitation a été envoyée à une autre adresse';
  END IF;

  -- Upsert membership (pas de contrainte unique connue → manuel)
  IF EXISTS (
    SELECT 1 FROM shop_memberships
    WHERE shop_id = v_inv.shop_id AND user_id = v_user_id
  ) THEN
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

-- ───────────────────────────────────────────────────────────────────────────
-- Nettoyage manuel des invitations expirées (à lancer périodiquement via pg_cron)
-- ───────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS cleanup_expired_invitations();
CREATE FUNCTION cleanup_expired_invitations()
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE v_count INT;
BEGIN
  WITH deleted AS (
    DELETE FROM pending_invitations WHERE expires_at < now() RETURNING 1
  ) SELECT count(*) INTO v_count FROM deleted;
  RETURN v_count;
END $fn$;
REVOKE ALL ON FUNCTION cleanup_expired_invitations() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cleanup_expired_invitations() TO authenticated;
