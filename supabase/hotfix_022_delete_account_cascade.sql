-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_022_delete_account_cascade.sql
--
-- Refonte de delete_user_account pour :
--
-- 1. Supprimer EFFECTIVEMENT auth.users — le hotfix précédent avalait l'erreur
--    silencieusement. Cause typique : auth.identities/auth.sessions ont une
--    FK vers auth.users et bloquent le DELETE. On les purge d'abord.
--
-- 2. Cascader la suppression sur tous les EMPLOYÉS créés par cet admin
--    (shop_memberships.created_by = admin) : leur auth.users, profile,
--    subscriptions, memberships, identities sont supprimés en même temps.
--
-- 3. Faire échouer la fonction VISIBLEMENT si auth.users n'a pas pu être
--    supprimé, plutôt que de retourner OK avec un compte fantôme.
-- ════════════════════════════════════════════════════════════════════════════

-- ── Helper : supprimer un user dans auth.* ────────────────────────────────
-- Ordre : refresh_tokens → sessions → identities → mfa_factors → users.
-- Chaque table est gardée par EXCEPTION WHEN undefined_table pour rester
-- compatible avec différentes versions de Supabase.
CREATE OR REPLACE FUNCTION public._purge_auth_user(p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $purge_auth$
DECLARE
  v_deleted BOOLEAN := false;
BEGIN
  BEGIN DELETE FROM auth.refresh_tokens WHERE user_id::text = p_user_id::text;
  EXCEPTION WHEN undefined_table THEN NULL; WHEN undefined_column THEN NULL; END;

  BEGIN DELETE FROM auth.sessions       WHERE user_id = p_user_id;
  EXCEPTION WHEN undefined_table THEN NULL; END;

  BEGIN DELETE FROM auth.mfa_factors    WHERE user_id = p_user_id;
  EXCEPTION WHEN undefined_table THEN NULL; END;

  BEGIN DELETE FROM auth.mfa_challenges
         WHERE factor_id IN (SELECT id FROM auth.mfa_factors WHERE user_id = p_user_id);
  EXCEPTION WHEN undefined_table THEN NULL; END;

  BEGIN DELETE FROM auth.identities     WHERE user_id = p_user_id;
  EXCEPTION WHEN undefined_table THEN NULL; END;

  BEGIN DELETE FROM auth.one_time_tokens WHERE user_id = p_user_id;
  EXCEPTION WHEN undefined_table THEN NULL; END;

  -- Le DELETE final — si ça plante ici, on REMONTE l'erreur.
  DELETE FROM auth.users WHERE id = p_user_id;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted::boolean;
END;
$purge_auth$;

ALTER FUNCTION public._purge_auth_user(UUID) OWNER TO postgres;
REVOKE ALL ON FUNCTION public._purge_auth_user(UUID) FROM PUBLIC;

-- ── delete_user_account v3 : cascade complète ─────────────────────────────
DROP FUNCTION IF EXISTS public.delete_user_account(UUID);
CREATE FUNCTION public.delete_user_account(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET row_security = off
SET search_path = public, pg_temp
AS $del_acc$
DECLARE
  v_is_sa            BOOLEAN;
  v_email            TEXT;
  v_name             TEXT;
  v_uid_t            TEXT := p_user_id::text;
  v_shops            TEXT[];
  v_employees        UUID[];
  v_emp              UUID;
  v_emp_email        TEXT;
  v_deleted_employees INT := 0;
  v_auth_deleted     BOOLEAN;
BEGIN
  -- ── Garde
  SELECT COALESCE(is_super_admin, false) INTO v_is_sa
    FROM profiles WHERE id::text = auth.uid()::text;

  IF NOT v_is_sa AND v_uid_t <> auth.uid()::text THEN
    RAISE EXCEPTION 'Non autorisé : vous ne pouvez supprimer que votre propre compte';
  END IF;

  SELECT email, name INTO v_email, v_name
    FROM profiles WHERE id::text = v_uid_t;

  -- ── 1. Récupérer toutes les boutiques possédées
  SELECT ARRAY(SELECT id::text FROM shops WHERE owner_id::text = v_uid_t)
    INTO v_shops;

  -- ── 2. Récupérer tous les employés créés par cet admin
  --     (que ce soit dans ses boutiques ou ailleurs — on cascade tout ce
  --     qui a `created_by = admin`).
  SELECT ARRAY(
    SELECT DISTINCT user_id::uuid
      FROM shop_memberships
     WHERE created_by::text = v_uid_t
       AND user_id::text <> v_uid_t
  ) INTO v_employees;

  -- ── 3. Purger les dépendances des boutiques (stock_*, products, etc.)
  PERFORM public._purge_shop_dependents(v_shops);

  -- ── 4. Supprimer chaque employé en cascade
  IF array_length(v_employees, 1) IS NOT NULL THEN
    FOREACH v_emp IN ARRAY v_employees LOOP
      SELECT email INTO v_emp_email FROM profiles WHERE id = v_emp;

      -- Subscriptions de l'employé
      BEGIN DELETE FROM subscriptions WHERE user_id::text = v_emp::text;
      EXCEPTION WHEN undefined_table THEN NULL; END;

      -- Toutes les memberships de l'employé (y compris hors des shops de l'admin)
      BEGIN DELETE FROM shop_memberships WHERE user_id::text = v_emp::text;
      EXCEPTION WHEN undefined_table THEN NULL; END;

      -- Profile
      DELETE FROM profiles WHERE id = v_emp;

      -- auth.* (cascade complète)
      BEGIN
        PERFORM public._purge_auth_user(v_emp);
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING '[delete_user_account] purge auth pour employé % : %',
          v_emp, SQLERRM;
      END;

      v_deleted_employees := v_deleted_employees + 1;
    END LOOP;
  END IF;

  -- ── 5. Supprimer les boutiques de l'admin
  DELETE FROM shops WHERE owner_id::text = v_uid_t;

  -- ── 6. Données liées directement à l'admin
  BEGIN DELETE FROM subscriptions WHERE user_id::text = v_uid_t;
  EXCEPTION WHEN undefined_table THEN NULL; END;

  BEGIN DELETE FROM shop_memberships WHERE user_id::text = v_uid_t;
  EXCEPTION WHEN undefined_table THEN NULL; END;

  BEGIN DELETE FROM pending_invitations
         WHERE invited_by::text = v_uid_t OR email = v_email;
  EXCEPTION WHEN undefined_table THEN NULL; WHEN undefined_column THEN NULL; END;

  -- ── 7. Profile admin
  DELETE FROM profiles WHERE id::text = v_uid_t;

  -- ── 8. Log AVANT de supprimer auth.users (sinon FK actor_id casse)
  INSERT INTO activity_logs (
    actor_id, actor_email, action, target_type, target_id, target_label, details
  )
  VALUES (
    auth.uid(),
    (SELECT email FROM auth.users WHERE id::text = auth.uid()::text),
    CASE WHEN auth.uid()::text = v_uid_t THEN 'account_deleted' ELSE 'user_deleted' END,
    'user', v_uid_t, v_name,
    jsonb_build_object(
      'email', v_email,
      'by_super_admin', v_is_sa,
      'cascaded_employees', v_deleted_employees
    )
  );

  -- ── 9. auth.users de l'admin (en dernier — supprime aussi la session)
  v_auth_deleted := public._purge_auth_user(p_user_id);

  IF NOT v_auth_deleted THEN
    -- Échec critique : profile supprimé mais auth.users intact → utilisateur
    -- pourrait encore se connecter. On remonte l'erreur pour que l'app
    -- alerte l'utilisateur.
    RAISE EXCEPTION 'Compte partiellement supprimé : auth.users intact. '
                    'Privilèges insuffisants. Le compte peut encore se connecter.';
  END IF;

  RETURN jsonb_build_object(
    'user_id', v_uid_t,
    'auth_deleted', v_auth_deleted,
    'cascaded_employees', v_deleted_employees,
    'shops_deleted', COALESCE(array_length(v_shops, 1), 0)
  );
END $del_acc$;

ALTER FUNCTION public.delete_user_account(UUID) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.delete_user_account(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_user_account(UUID) TO authenticated;

-- ── Grant DELETE explicite sur les tables auth.* ──────────────────────────
DO $grant_auth$
BEGIN
  GRANT DELETE ON auth.users          TO postgres;
  BEGIN GRANT DELETE ON auth.identities     TO postgres; EXCEPTION WHEN undefined_table THEN NULL; END;
  BEGIN GRANT DELETE ON auth.sessions       TO postgres; EXCEPTION WHEN undefined_table THEN NULL; END;
  BEGIN GRANT DELETE ON auth.refresh_tokens TO postgres; EXCEPTION WHEN undefined_table THEN NULL; END;
  BEGIN GRANT DELETE ON auth.mfa_factors    TO postgres; EXCEPTION WHEN undefined_table THEN NULL; END;
  BEGIN GRANT DELETE ON auth.mfa_challenges TO postgres; EXCEPTION WHEN undefined_table THEN NULL; END;
  BEGIN GRANT DELETE ON auth.one_time_tokens TO postgres; EXCEPTION WHEN undefined_table THEN NULL; END;
EXCEPTION WHEN insufficient_privilege THEN NULL;
END $grant_auth$;

-- ════════════════════════════════════════════════════════════════════════════
-- Cleanup : purger les comptes orphelins existants
-- (auth.users sans profile correspondant — résultat d'anciennes suppressions
-- partielles).
-- ════════════════════════════════════════════════════════════════════════════
DO $cleanup$
DECLARE
  v_orphan UUID;
BEGIN
  FOR v_orphan IN
    SELECT u.id FROM auth.users u
     LEFT JOIN profiles p ON p.id = u.id
     WHERE p.id IS NULL
       AND u.email IS NOT NULL
  LOOP
    BEGIN
      PERFORM public._purge_auth_user(v_orphan);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Cleanup orphan % : %', v_orphan, SQLERRM;
    END;
  END LOOP;
END $cleanup$;
