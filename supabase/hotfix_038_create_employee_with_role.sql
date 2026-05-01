-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_038_create_employee_with_role.sql
--
-- Étend `create_employee` (hotfix_018) avec un paramètre `p_role`
-- (admin | user, défaut 'user').
--
-- Motivation : le rôle d'un nouvel employé est désormais déterminé au
-- moment de la création via le préréglage choisi dans le form RH (preset
-- "Admin" → role='admin'). Le trigger trg_enforce_max_admins (hotfix_024)
-- s'applique à l'INSERT et bloque si la limite des 3 admins (owner
-- inclus) est atteinte.
--
-- Rétrocompat : la nouvelle signature est ajoutée à côté de l'ancienne.
-- L'ancien `create_employee(p_shop_id, p_email, p_password, p_full_name,
-- p_permissions, p_status)` est conservé tant qu'aucun client ne l'appelle
-- — supabase-flutter route automatiquement sur la nouvelle quand on lui
-- passe `p_role`. Une fois tous les clients à jour, le DROP de l'ancienne
-- est sûr.
-- ════════════════════════════════════════════════════════════════════════════

-- Drop de la signature à 7 paramètres si elle existait déjà (idempotent).
DROP FUNCTION IF EXISTS public.create_employee(
  TEXT, TEXT, TEXT, TEXT, JSONB, TEXT, TEXT
);

CREATE OR REPLACE FUNCTION public.create_employee(
  p_shop_id     TEXT,
  p_email       TEXT,
  p_password    TEXT,
  p_full_name   TEXT,
  p_permissions JSONB,
  p_status      TEXT DEFAULT 'active',
  p_role        TEXT DEFAULT 'user'
) RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp
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
  IF p_role NOT IN ('admin','user') THEN
    RAISE EXCEPTION 'Rôle invalide (admin ou user uniquement)'
      USING ERRCODE = '22023';
  END IF;

  -- 3. Email déjà utilisé ?
  SELECT id INTO v_existing FROM auth.users WHERE email = v_email;
  IF v_existing IS NOT NULL THEN
    RAISE EXCEPTION 'Cet email est déjà utilisé' USING ERRCODE = '23505';
  END IF;

  -- 4. Créer le user dans auth.users
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

  -- 6. Profile public
  INSERT INTO profiles (id, name, email, created_at)
  VALUES (v_user_id, p_full_name, v_email, now())
  ON CONFLICT (id) DO UPDATE
    SET name = EXCLUDED.name, email = EXCLUDED.email;

  -- 7. Membership avec rôle + permissions granulaires.
  --    ⚠ Le trigger trg_enforce_max_admins peut throw 23514 ici si
  --    p_role='admin' et que la boutique a déjà 3 admins actifs.
  INSERT INTO shop_memberships
      (user_id, shop_id, role, permissions, status,
       created_by, created_at, full_name)
  VALUES
      (v_user_id::text, p_shop_id, p_role, p_permissions, p_status,
       auth.uid()::text, now(), p_full_name);

  RETURN v_user_id::text;
END;
$cre_emp$;

ALTER FUNCTION public.create_employee(
  TEXT, TEXT, TEXT, TEXT, JSONB, TEXT, TEXT
) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.create_employee(
  TEXT, TEXT, TEXT, TEXT, JSONB, TEXT, TEXT
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_employee(
  TEXT, TEXT, TEXT, TEXT, JSONB, TEXT, TEXT
) TO authenticated;
