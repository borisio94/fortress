-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_104_invitation_v2.sql  —  Invitation employé par LIEN (magic-link)
--
-- Aligne le système d'invitation (hotfix_004) sur la création d'employé
-- riche (hotfix_038) pour ne RIEN régresser :
--   • rôles 'admin'/'user' (au lieu de admin/manager/cashier)
--   • porte les PERMISSIONS granulaires + le STATUT + le NOM dans l'invitation
--   • autorise l'OWNER à inviter (bug : l'ancienne RPC exigeait role='admin')
--   • à l'acceptation, écrit role + permissions + status + full_name dans
--     shop_memberships (membership identique à la création directe).
--
-- Flux : owner génère un lien → partage (WhatsApp/copie) → l'employé ouvre
-- /accept-invite?token=… → crée son mot de passe (ou se connecte) → rattaché.
--
-- Idempotent.
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1. Schéma pending_invitations : rôles + colonnes riches ─────────────────
-- Migration des anciens rôles éventuels avant de poser la nouvelle contrainte.
UPDATE pending_invitations SET role = 'user'  WHERE role IN ('cashier','manager');
-- (les 'admin' restent 'admin')

ALTER TABLE pending_invitations DROP CONSTRAINT IF EXISTS pending_invitations_role_check;
ALTER TABLE pending_invitations
  ALTER COLUMN role SET DEFAULT 'user',
  ADD CONSTRAINT pending_invitations_role_check CHECK (role IN ('admin','user'));

ALTER TABLE pending_invitations
  ADD COLUMN IF NOT EXISTS permissions jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS status      text  NOT NULL DEFAULT 'active',
  ADD COLUMN IF NOT EXISTS full_name   text;

-- ── 2. RLS : l'owner aussi gère les invitations (pas que role='admin') ─────
DROP POLICY IF EXISTS pending_invitations_shop_admin ON pending_invitations;
CREATE POLICY pending_invitations_shop_admin ON pending_invitations FOR ALL
  USING (public._is_shop_admin(shop_id))
  WITH CHECK (public._is_shop_admin(shop_id));

-- ── 3. create_shop_invitation enrichie ─────────────────────────────────────
DROP FUNCTION IF EXISTS create_shop_invitation(TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS create_shop_invitation(TEXT, TEXT, TEXT, JSONB, TEXT, TEXT);
CREATE FUNCTION create_shop_invitation(
  p_shop_id     TEXT,
  p_email       TEXT,
  p_role        TEXT  DEFAULT 'user',
  p_permissions JSONB DEFAULT '[]'::jsonb,
  p_status      TEXT  DEFAULT 'active',
  p_full_name   TEXT  DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp
SET row_security = off
AS $fn$
DECLARE
  v_token      TEXT;
  v_id         UUID;
  v_email_norm TEXT := lower(trim(p_email));
BEGIN
  -- Autorisé : admin/owner de la boutique OU super-admin.
  IF NOT (public._is_shop_admin(p_shop_id) OR public._is_super_admin()) THEN
    RAISE EXCEPTION 'Non autorisé : admin de la boutique requis' USING ERRCODE = '42501';
  END IF;
  IF p_role NOT IN ('admin','user') THEN
    RAISE EXCEPTION 'Rôle invalide (admin ou user)' USING ERRCODE = 'P0001';
  END IF;

  -- Empêcher d'inviter un user déjà membre.
  IF EXISTS (
    SELECT 1 FROM profiles p
      JOIN shop_memberships m ON m.user_id = p.id::text
    WHERE lower(p.email) = v_email_norm AND m.shop_id = p_shop_id
  ) THEN
    RAISE EXCEPTION 'Cet utilisateur est déjà membre de la boutique' USING ERRCODE = 'P0002';
  END IF;

  v_token := replace(replace(replace(
    encode(gen_random_bytes(24), 'base64'), '/', '_'), '+', '-'), '=', '');

  INSERT INTO pending_invitations
      (shop_id, email, role, permissions, status, full_name, token, invited_by)
  VALUES
      (p_shop_id, v_email_norm, p_role, p_permissions, p_status, p_full_name,
       v_token, auth.uid())
  ON CONFLICT (shop_id, email) DO UPDATE
    SET token       = EXCLUDED.token,
        role        = EXCLUDED.role,
        permissions = EXCLUDED.permissions,
        status      = EXCLUDED.status,
        full_name   = EXCLUDED.full_name,
        invited_by  = EXCLUDED.invited_by,
        created_at  = now(),
        expires_at  = now() + interval '7 days'
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('id', v_id, 'token', v_token);
END $fn$;
REVOKE ALL ON FUNCTION
  create_shop_invitation(TEXT, TEXT, TEXT, JSONB, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  create_shop_invitation(TEXT, TEXT, TEXT, JSONB, TEXT, TEXT) TO authenticated;

-- ── 4. get_invitation_info : ajoute full_name ──────────────────────────────
DROP FUNCTION IF EXISTS get_invitation_info(TEXT);
CREATE FUNCTION get_invitation_info(p_token TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
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
    'full_name',  v_inv.full_name,
    'shop_id',    v_inv.shop_id,
    'shop_name',  v_shop_name,
    'expires_at', v_inv.expires_at
  );
END $fn$;
REVOKE ALL ON FUNCTION get_invitation_info(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_invitation_info(TEXT) TO anon, authenticated;

-- ── 5. accept_shop_invitation : écrit role + permissions + status + nom ─────
DROP FUNCTION IF EXISTS accept_shop_invitation(TEXT);
CREATE FUNCTION accept_shop_invitation(p_token TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
SET row_security = off
AS $fn$
DECLARE
  v_inv        pending_invitations%ROWTYPE;
  v_user_id    TEXT;
  v_user_email TEXT;
BEGIN
  SELECT * INTO v_inv FROM pending_invitations WHERE token = p_token;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invitation introuvable'; END IF;
  IF v_inv.expires_at < now() THEN RAISE EXCEPTION 'Invitation expirée'; END IF;

  v_user_id    := (auth.uid())::text;
  v_user_email := lower(auth.jwt() ->> 'email');
  IF v_user_id IS NULL OR v_user_email IS NULL THEN
    RAISE EXCEPTION 'Connexion requise';
  END IF;
  IF lower(v_inv.email) <> v_user_email THEN
    RAISE EXCEPTION 'Cette invitation a été envoyée à une autre adresse';
  END IF;

  IF EXISTS (
    SELECT 1 FROM shop_memberships
    WHERE shop_id = v_inv.shop_id AND user_id = v_user_id
  ) THEN
    UPDATE shop_memberships
       SET role        = v_inv.role,
           permissions = v_inv.permissions,
           status      = v_inv.status,
           full_name   = COALESCE(v_inv.full_name, full_name)
     WHERE shop_id = v_inv.shop_id AND user_id = v_user_id;
  ELSE
    INSERT INTO shop_memberships
        (shop_id, user_id, role, permissions, status, full_name,
         created_by, created_at)
    VALUES
        (v_inv.shop_id, v_user_id, v_inv.role, v_inv.permissions,
         v_inv.status, v_inv.full_name, v_inv.invited_by, now());
  END IF;

  DELETE FROM pending_invitations WHERE id = v_inv.id;

  -- Journalisation best-effort : activity_logs.shop_id est de type UUID alors
  -- que pending_invitations.shop_id est text → cast ::uuid. Encadré pour ne
  -- JAMAIS faire échouer l'acceptation si la trace pose problème.
  BEGIN
    INSERT INTO activity_logs (actor_id, actor_email, action, target_type,
                               target_id, shop_id, details)
    VALUES (auth.uid(), v_user_email, 'invitation_accepted', 'shop',
            v_inv.shop_id, v_inv.shop_id::uuid,
            jsonb_build_object('role', v_inv.role));
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object('shop_id', v_inv.shop_id, 'role', v_inv.role);
END $fn$;
REVOKE ALL ON FUNCTION accept_shop_invitation(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION accept_shop_invitation(TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';
