-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_018_employees.sql
-- Refonte de la gestion des employés (Ressources Humaines).
--
-- Décisions :
--   - Création directe par l'admin/owner (pas d'invitation par email).
--   - Permissions granulaires stockées en JSONB sur shop_memberships.
--   - Statut : active | suspended | archived (suppression douce).
--   - L'auth est créée via INSERT direct dans auth.users + auth.identities,
--     password hashé bcrypt via pgcrypto.
--
-- ⚠ Casts ::text systématiques dans les comparaisons d'IDs : la base
--   existante stocke certaines clés (shop_memberships.user_id, .shop_id,
--   shops.id…) en TEXT plutôt qu'UUID. Caster les deux côtés évite
--   l'erreur 42883 (text = uuid).
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1. Extensions ─────────────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ── 2. Étendre shop_memberships ──────────────────────────────────────────
ALTER TABLE shop_memberships ADD COLUMN IF NOT EXISTS permissions JSONB DEFAULT '[]'::jsonb;
ALTER TABLE shop_memberships ADD COLUMN IF NOT EXISTS status      TEXT  DEFAULT 'active';
-- created_by sans FK pour éviter un type clash si la colonne user_id existante
-- est TEXT et auth.users.id est UUID. Stocké en TEXT pour rester compatible.
ALTER TABLE shop_memberships ADD COLUMN IF NOT EXISTS created_by  TEXT;
ALTER TABLE shop_memberships ADD COLUMN IF NOT EXISTS created_at  TIMESTAMPTZ DEFAULT now();
ALTER TABLE shop_memberships ADD COLUMN IF NOT EXISTS full_name   TEXT;

-- Contrainte CHECK status (idempotent)
DO $chk$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname='shop_memberships_status_chk')
  THEN ALTER TABLE shop_memberships DROP CONSTRAINT shop_memberships_status_chk;
  END IF;
END $chk$;

ALTER TABLE shop_memberships
  ADD CONSTRAINT shop_memberships_status_chk
  CHECK (status IN ('active','suspended','archived'));

-- Contrainte CHECK role (idempotent — toute version pré-existante est
-- supprimée, peu importe son nom). Valeurs élargies pour rétrocompat
-- avec les schémas legacy qui acceptaient manager/cashier/employee/owner.
DO $drop_role_chk$
DECLARE v_conname text;
BEGIN
  FOR v_conname IN
    SELECT conname FROM pg_constraint
     WHERE conrelid = 'shop_memberships'::regclass
       AND contype = 'c'
       AND pg_get_constraintdef(oid) ILIKE '%role%'
       AND conname <> 'shop_memberships_status_chk'
  LOOP
    EXECUTE format('ALTER TABLE shop_memberships DROP CONSTRAINT %I',
        v_conname);
  END LOOP;
END $drop_role_chk$;

ALTER TABLE shop_memberships
  ADD CONSTRAINT shop_memberships_role_chk
  CHECK (role IN ('admin', 'manager', 'cashier', 'user', 'employee', 'owner'));

CREATE INDEX IF NOT EXISTS idx_memberships_shop_status
  ON shop_memberships(shop_id, status);

-- ── 3. Migration : permissions par défaut depuis le rôle legacy ──────────
UPDATE shop_memberships SET permissions = '[
  "inventory.view","inventory.write","inventory.delete","inventory.stock",
  "caisse.access","caisse.sell","caisse.edit_orders","caisse.scheduled",
  "crm.view","crm.write","crm.delete",
  "finance.view","finance.expenses","finance.export",
  "shop.settings","shop.locations","shop.activity"
]'::jsonb
 WHERE role = 'admin'
   AND (permissions IS NULL OR permissions = '[]'::jsonb);

UPDATE shop_memberships SET permissions = '[
  "inventory.view","caisse.access","caisse.sell","crm.view"
]'::jsonb
 WHERE role = 'user'
   AND (permissions IS NULL OR permissions = '[]'::jsonb);

-- ── 4. Helper : l'utilisateur courant est-il admin/owner du shop ? ───────
-- Idempotence : sur une base où le hotfix a déjà tourné, les policies
-- shop_memberships_{select,write} (créées plus bas, §11) dépendent de
-- _is_shop_admin(TEXT) → un DROP FUNCTION échoue avec ERRCODE 2BP01.
-- On évite le DROP : la signature ne change pas, donc CREATE OR REPLACE
-- met à jour le corps en conservant les dépendances RLS.
-- Pour la version legacy (UUID), on garde le DROP avec CASCADE — elle
-- n'est plus utilisée par le code applicatif, et si une policy historique
-- y référait, elle sera recréée par la §11 plus bas.
DROP FUNCTION IF EXISTS public._is_shop_admin(UUID) CASCADE;
CREATE OR REPLACE FUNCTION public._is_shop_admin(p_shop_id TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql STABLE SECURITY DEFINER
AS $is_adm$
BEGIN
  RETURN
    EXISTS (
      SELECT 1 FROM shops
       WHERE id::text = p_shop_id
         AND owner_id::text = auth.uid()::text
    )
    OR EXISTS (
      SELECT 1 FROM shop_memberships
       WHERE shop_id::text = p_shop_id
         AND user_id::text = auth.uid()::text
         AND role = 'admin'
         AND COALESCE(status, 'active') = 'active'
    )
    OR EXISTS (
      SELECT 1 FROM profiles
       WHERE id::text = auth.uid()::text
         AND is_super_admin = true
    );
END;
$is_adm$;

GRANT EXECUTE ON FUNCTION public._is_shop_admin(TEXT) TO authenticated;

-- ── 5. RPC : create_employee ─────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.create_employee(UUID, TEXT, TEXT, TEXT, JSONB, TEXT);
DROP FUNCTION IF EXISTS public.create_employee(TEXT, TEXT, TEXT, TEXT, JSONB, TEXT);
CREATE OR REPLACE FUNCTION public.create_employee(
  p_shop_id     TEXT,
  p_email       TEXT,
  p_password    TEXT,
  p_full_name   TEXT,
  p_permissions JSONB,
  p_status      TEXT DEFAULT 'active'
) RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER
AS $cre_emp$
DECLARE
  v_user_id  UUID;
  v_existing UUID;
  v_email    TEXT;
BEGIN
  -- 1. Garde
  IF NOT public._is_shop_admin(p_shop_id) THEN
    RAISE EXCEPTION 'Réservé aux administrateurs de la boutique'
      USING ERRCODE = '42501';
  END IF;

  -- 2. Validation
  v_email := LOWER(TRIM(p_email));
  IF v_email = '' OR position('@' IN v_email) = 0 THEN
    RAISE EXCEPTION 'Adresse email invalide' USING ERRCODE = '22023';
  END IF;
  IF length(p_password) < 6 THEN
    RAISE EXCEPTION 'Mot de passe trop court (min 6 caractères)'
      USING ERRCODE = '22023';
  END IF;
  IF p_status NOT IN ('active','suspended','archived') THEN
    RAISE EXCEPTION 'Statut invalide' USING ERRCODE = '22023';
  END IF;

  -- 3. Email déjà utilisé ?
  SELECT id INTO v_existing FROM auth.users WHERE email = v_email;
  IF v_existing IS NOT NULL THEN
    RAISE EXCEPTION 'Cet email est déjà utilisé' USING ERRCODE = '23505';
  END IF;

  -- 4. Créer le user dans auth.users
  --    ⚠ Les colonnes *_token / email_change / phone_change DOIVENT être ''
  --    et non NULL : GoTrue fait des comparaisons texte dessus, et un NULL
  --    fait échouer la connexion ("email ou mot de passe incorrect")
  --    silencieusement, alors que la ligne existe bien.
  v_user_id := gen_random_uuid();
  INSERT INTO auth.users (
    id, instance_id, email, encrypted_password,
    email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data,
    aud, role,
    created_at, updated_at,
    confirmation_token, recovery_token,
    email_change, email_change_token_new, email_change_token_current,
    reauthentication_token,
    phone_change, phone_change_token,
    is_super_admin
  )
  VALUES (
    v_user_id,
    -- Cast ::uuid explicite : auth.users.instance_id est UUID, le literal
    -- TEXT par défaut → erreur 42804 dans certaines configurations.
    '00000000-0000-0000-0000-000000000000'::uuid,
    v_email,
    crypt(p_password, gen_salt('bf')),
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    jsonb_build_object('name', p_full_name),
    'authenticated',
    'authenticated',
    now(), now(),
    '', '',
    '', '', '',
    '',
    '', '',
    false
  );

  -- 5. Identité (provider email)
  INSERT INTO auth.identities (
    id, user_id, identity_data, provider, provider_id,
    created_at, updated_at, last_sign_in_at
  )
  VALUES (
    gen_random_uuid(),
    v_user_id,
    jsonb_build_object('sub', v_user_id::text, 'email', v_email),
    'email',
    v_email,
    now(), now(), now()
  );

  -- 6. Profile public (profiles.id est UUID dans cette base — pas de cast)
  INSERT INTO profiles (id, name, email, created_at)
  VALUES (v_user_id, p_full_name, v_email, now())
  ON CONFLICT (id) DO UPDATE
    SET name = EXCLUDED.name, email = EXCLUDED.email;

  -- 7. Membership avec permissions granulaires
  INSERT INTO shop_memberships
      (user_id, shop_id, role, permissions, status,
       created_by, created_at, full_name)
  VALUES
      (v_user_id::text, p_shop_id, 'user', p_permissions, p_status,
       auth.uid()::text, now(), p_full_name);

  RETURN v_user_id::text;
END;
$cre_emp$;

GRANT EXECUTE ON FUNCTION public.create_employee(
  TEXT, TEXT, TEXT, TEXT, JSONB, TEXT
) TO authenticated;

-- ── 6. RPC : update_employee_permissions ─────────────────────────────────
DROP FUNCTION IF EXISTS public.update_employee_permissions(UUID, UUID, JSONB);
DROP FUNCTION IF EXISTS public.update_employee_permissions(TEXT, TEXT, JSONB);
CREATE OR REPLACE FUNCTION public.update_employee_permissions(
  p_shop_id     TEXT,
  p_user_id     TEXT,
  p_permissions JSONB
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
AS $upd_perm$
BEGIN
  IF NOT public._is_shop_admin(p_shop_id) THEN
    RAISE EXCEPTION 'Réservé aux administrateurs de la boutique'
      USING ERRCODE = '42501';
  END IF;

  UPDATE shop_memberships
     SET permissions = p_permissions
   WHERE shop_id::text = p_shop_id AND user_id::text = p_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Employé introuvable dans cette boutique'
      USING ERRCODE = 'P0002';
  END IF;
END;
$upd_perm$;

GRANT EXECUTE ON FUNCTION public.update_employee_permissions(TEXT, TEXT, JSONB)
  TO authenticated;

-- ── 7. RPC : update_employee_profile ─────────────────────────────────────
DROP FUNCTION IF EXISTS public.update_employee_profile(UUID, UUID, TEXT, TEXT);
DROP FUNCTION IF EXISTS public.update_employee_profile(TEXT, TEXT, TEXT, TEXT);
CREATE OR REPLACE FUNCTION public.update_employee_profile(
  p_shop_id   TEXT,
  p_user_id   TEXT,
  p_full_name TEXT,
  p_role      TEXT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
AS $upd_prof$
BEGIN
  IF NOT public._is_shop_admin(p_shop_id) THEN
    RAISE EXCEPTION 'Réservé aux administrateurs de la boutique'
      USING ERRCODE = '42501';
  END IF;
  IF p_role NOT IN ('admin','user') THEN
    RAISE EXCEPTION 'Rôle invalide' USING ERRCODE = '22023';
  END IF;

  UPDATE shop_memberships
     SET full_name = p_full_name,
         role      = p_role
   WHERE shop_id::text = p_shop_id AND user_id::text = p_user_id;

  IF p_full_name IS NOT NULL AND p_full_name <> '' THEN
    UPDATE profiles SET name = p_full_name WHERE id::text = p_user_id;
  END IF;
END;
$upd_prof$;

GRANT EXECUTE ON FUNCTION public.update_employee_profile(TEXT, TEXT, TEXT, TEXT)
  TO authenticated;

-- ── 8. RPC : set_employee_status ─────────────────────────────────────────
DROP FUNCTION IF EXISTS public.set_employee_status(UUID, UUID, TEXT);
DROP FUNCTION IF EXISTS public.set_employee_status(TEXT, TEXT, TEXT);
CREATE OR REPLACE FUNCTION public.set_employee_status(
  p_shop_id TEXT,
  p_user_id TEXT,
  p_status  TEXT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
AS $set_st$
BEGIN
  IF NOT public._is_shop_admin(p_shop_id) THEN
    RAISE EXCEPTION 'Réservé aux administrateurs de la boutique'
      USING ERRCODE = '42501';
  END IF;
  IF p_status NOT IN ('active','suspended','archived') THEN
    RAISE EXCEPTION 'Statut invalide' USING ERRCODE = '22023';
  END IF;

  UPDATE shop_memberships
     SET status = p_status
   WHERE shop_id::text = p_shop_id AND user_id::text = p_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Employé introuvable dans cette boutique'
      USING ERRCODE = 'P0002';
  END IF;
END;
$set_st$;

GRANT EXECUTE ON FUNCTION public.set_employee_status(TEXT, TEXT, TEXT)
  TO authenticated;

-- ── 9. RPC : delete_employee ─────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.delete_employee(UUID, UUID);
DROP FUNCTION IF EXISTS public.delete_employee(TEXT, TEXT);
CREATE OR REPLACE FUNCTION public.delete_employee(
  p_shop_id TEXT,
  p_user_id TEXT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
AS $del_emp$
BEGIN
  IF NOT public._is_shop_admin(p_shop_id) THEN
    RAISE EXCEPTION 'Réservé aux administrateurs de la boutique'
      USING ERRCODE = '42501';
  END IF;

  IF EXISTS (
    SELECT 1 FROM shops
     WHERE id::text = p_shop_id AND owner_id::text = p_user_id
  ) THEN
    RAISE EXCEPTION 'Impossible de retirer le propriétaire de la boutique'
      USING ERRCODE = '23503';
  END IF;

  DELETE FROM shop_memberships
   WHERE shop_id::text = p_shop_id AND user_id::text = p_user_id;
END;
$del_emp$;

GRANT EXECUTE ON FUNCTION public.delete_employee(TEXT, TEXT)
  TO authenticated;

-- ── 10. RPC : list_shop_employees ────────────────────────────────────────
DROP FUNCTION IF EXISTS public.list_shop_employees(UUID);
DROP FUNCTION IF EXISTS public.list_shop_employees(TEXT);
CREATE OR REPLACE FUNCTION public.list_shop_employees(p_shop_id TEXT)
RETURNS TABLE (
  user_id     TEXT,
  full_name   TEXT,
  email       TEXT,
  role        TEXT,
  permissions JSONB,
  status      TEXT,
  created_at  TIMESTAMPTZ,
  created_by  TEXT,
  is_owner    BOOLEAN
) LANGUAGE plpgsql STABLE SECURITY DEFINER
AS $list_emp$
BEGIN
  IF NOT public._is_shop_admin(p_shop_id) THEN
    RAISE EXCEPTION 'Réservé aux administrateurs de la boutique'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    sm.user_id::text,
    COALESCE(sm.full_name, p.name)              AS full_name,
    p.email                                      AS email,
    sm.role                                      AS role,
    COALESCE(sm.permissions, '[]'::jsonb)        AS permissions,
    COALESCE(sm.status, 'active')                AS status,
    sm.created_at                                AS created_at,
    sm.created_by                                AS created_by,
    EXISTS (SELECT 1 FROM shops
             WHERE id::text = p_shop_id
               AND owner_id::text = sm.user_id::text) AS is_owner
  FROM shop_memberships sm
  LEFT JOIN profiles p ON p.id::text = sm.user_id::text
  WHERE sm.shop_id::text = p_shop_id
  ORDER BY is_owner DESC, sm.created_at ASC NULLS LAST;
END;
$list_emp$;

GRANT EXECUTE ON FUNCTION public.list_shop_employees(TEXT) TO authenticated;

-- ── 11. RLS sur shop_memberships ────────────────────────────────────────
ALTER TABLE shop_memberships ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS shop_memberships_select ON shop_memberships;
CREATE POLICY shop_memberships_select ON shop_memberships FOR SELECT
  USING (
    user_id::text = auth.uid()::text
    OR public._is_shop_admin(shop_id::text)
  );

DROP POLICY IF EXISTS shop_memberships_write ON shop_memberships;
CREATE POLICY shop_memberships_write ON shop_memberships FOR ALL
  USING       (public._is_shop_admin(shop_id::text))
  WITH CHECK  (public._is_shop_admin(shop_id::text));
