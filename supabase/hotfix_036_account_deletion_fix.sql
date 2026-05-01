-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_036_account_deletion_fix.sql
--
-- Corrige deux bugs bloquants sur la suppression de compte :
--
-- 1. Le trigger `trg_protect_owner_delete` (hotfix_025) bloquait
--    `delete_user_account` parce que `_purge_shop_dependents` (hotfix_019)
--    supprime les shop_memberships AVANT les shops. Le trigger voit que la
--    `shops` row existe encore et raise '42501 Impossible de retirer le
--    propriétaire'.
--    → Le trigger respecte désormais un flag de session
--      `app.bypass_owner_protection`. Les RPCs SECURITY DEFINER qui prennent
--      en charge la suppression complète du shop dans la même transaction
--      peuvent positionner ce flag. Les UI normales (suppression manuelle
--      d'une membership) restent protégées comme avant.
--
-- 2. `get_user_summary` (hotfix_002) comparait `shops.owner_id = p_user_id`
--    sans cast ::text. Si `owner_id` est stocké en TEXT (legacy), Postgres
--    raise '42883 operator does not exist: text = uuid'.
--    → Casts ::text systématiques, cohérent avec le reste des RPCs (cf.
--      commentaire de hotfix_019:11).
-- ════════════════════════════════════════════════════════════════════════════


-- ── 1. Trigger protect_owner_delete v2 : honore le flag bypass ────────────
DROP TRIGGER  IF EXISTS trg_protect_owner_delete ON shop_memberships;
DROP FUNCTION IF EXISTS public.protect_owner_delete() CASCADE;

CREATE OR REPLACE FUNCTION public.protect_owner_delete()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $protect$
BEGIN
  IF OLD.is_owner = true THEN
    -- Bypass : un RPC SECURITY DEFINER qui supprime aussi le shop dans la
    -- même transaction peut se signaler via ce flag de session.
    IF current_setting('app.bypass_owner_protection', true) = 'on' THEN
      RETURN OLD;
    END IF;

    -- Sinon : ne laisse passer que si le shop a déjà été supprimé dans la
    -- même transaction (cascade légitime ON DELETE CASCADE shops → memberships).
    IF EXISTS (SELECT 1 FROM shops WHERE id::text = OLD.shop_id::text) THEN
      RAISE EXCEPTION 'Impossible de retirer le propriétaire de la boutique. '
                      'Supprimez d''abord la boutique elle-même.'
        USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN OLD;
END;
$protect$;

CREATE TRIGGER trg_protect_owner_delete
BEFORE DELETE ON shop_memberships
FOR EACH ROW EXECUTE FUNCTION public.protect_owner_delete();


-- ── 2. delete_user_account v4 : pose le flag bypass avant la cascade ──────
-- Logique identique à hotfix_022 (cascade employés créés par l'admin, purge
-- auth.users en dernier, RAISE si auth.users non supprimé), avec en plus le
-- `set_config('app.bypass_owner_protection', 'on', true)` qui désactive la
-- garde du trigger pour cette transaction uniquement.
DROP FUNCTION IF EXISTS public.delete_user_account(UUID);
CREATE FUNCTION public.delete_user_account(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET row_security = off
SET search_path = public, pg_temp
AS $del_acc$
DECLARE
  v_is_sa             BOOLEAN;
  v_email             TEXT;
  v_name              TEXT;
  v_uid_t             TEXT := p_user_id::text;
  v_shops             TEXT[];
  v_employees         UUID[];
  v_emp               UUID;
  v_emp_email         TEXT;
  v_deleted_employees INT := 0;
  v_auth_deleted      BOOLEAN;
BEGIN
  -- Garde : super-admin OU user supprimant son propre compte uniquement.
  SELECT COALESCE(is_super_admin, false) INTO v_is_sa
    FROM profiles WHERE id::text = auth.uid()::text;

  IF NOT v_is_sa AND v_uid_t <> auth.uid()::text THEN
    RAISE EXCEPTION 'Non autorisé : vous ne pouvez supprimer que votre propre compte';
  END IF;

  SELECT email, name INTO v_email, v_name
    FROM profiles WHERE id::text = v_uid_t;

  -- Désactiver le trigger protect_owner_delete pour cette transaction :
  -- on supprime aussi les shops, donc retirer la membership owner avant
  -- est légitime (la boutique entière disparaît dans la même xact).
  PERFORM set_config('app.bypass_owner_protection', 'on', true);

  -- 1. Récupérer toutes les boutiques possédées
  SELECT ARRAY(SELECT id::text FROM shops WHERE owner_id::text = v_uid_t)
    INTO v_shops;

  -- 2. Récupérer tous les employés créés par cet admin (cascade complète)
  SELECT ARRAY(
    SELECT DISTINCT user_id::uuid
      FROM shop_memberships
     WHERE created_by::text = v_uid_t
       AND user_id::text <> v_uid_t
  ) INTO v_employees;

  -- 3. Purger les dépendances des boutiques (stock_*, products, memberships, etc.)
  PERFORM public._purge_shop_dependents(v_shops);

  -- 4. Supprimer chaque employé en cascade
  IF array_length(v_employees, 1) IS NOT NULL THEN
    FOREACH v_emp IN ARRAY v_employees LOOP
      SELECT email INTO v_emp_email FROM profiles WHERE id = v_emp;

      BEGIN DELETE FROM subscriptions WHERE user_id::text = v_emp::text;
      EXCEPTION WHEN undefined_table THEN NULL; END;

      BEGIN DELETE FROM shop_memberships WHERE user_id::text = v_emp::text;
      EXCEPTION WHEN undefined_table THEN NULL; END;

      DELETE FROM profiles WHERE id = v_emp;

      BEGIN
        PERFORM public._purge_auth_user(v_emp);
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING '[delete_user_account] purge auth pour employé % : %',
          v_emp, SQLERRM;
      END;

      v_deleted_employees := v_deleted_employees + 1;
    END LOOP;
  END IF;

  -- 5. Supprimer les boutiques de l'admin
  DELETE FROM shops WHERE owner_id::text = v_uid_t;

  -- 6. Données liées directement à l'admin
  BEGIN DELETE FROM subscriptions WHERE user_id::text = v_uid_t;
  EXCEPTION WHEN undefined_table THEN NULL; END;

  BEGIN DELETE FROM shop_memberships WHERE user_id::text = v_uid_t;
  EXCEPTION WHEN undefined_table THEN NULL; END;

  BEGIN DELETE FROM pending_invitations
         WHERE invited_by::text = v_uid_t OR email = v_email;
  EXCEPTION WHEN undefined_table THEN NULL; WHEN undefined_column THEN NULL; END;

  -- 7. Profile admin
  DELETE FROM profiles WHERE id::text = v_uid_t;

  -- 8. Log AVANT de supprimer auth.users (sinon FK actor_id casse)
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

  -- 9. auth.users de l'admin (en dernier — supprime aussi la session)
  v_auth_deleted := public._purge_auth_user(p_user_id);

  IF NOT v_auth_deleted THEN
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


-- ── 3. get_user_summary v3 : casts ::text systématiques ───────────────────
DROP FUNCTION IF EXISTS get_user_summary(UUID);
CREATE FUNCTION get_user_summary(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_uid_t    TEXT := p_user_id::text;
  v_shops    INT;
  v_products INT;
  v_sales    INT;
  v_clients  INT;
BEGIN
  IF auth.uid()::text IS DISTINCT FROM v_uid_t AND NOT EXISTS (
    SELECT 1 FROM profiles
     WHERE id::text = auth.uid()::text AND is_super_admin = true
  ) THEN
    RAISE EXCEPTION 'Non autorisé';
  END IF;

  SELECT count(*) INTO v_shops
    FROM shops
   WHERE owner_id::text = v_uid_t;

  SELECT count(*) INTO v_products
    FROM products
   WHERE store_id::text IN (
     SELECT id::text FROM shops WHERE owner_id::text = v_uid_t
   );

  SELECT count(*) INTO v_sales
    FROM orders
   WHERE shop_id::text IN (
     SELECT id::text FROM shops WHERE owner_id::text = v_uid_t
   );

  SELECT count(*) INTO v_clients
    FROM clients
   WHERE store_id::text IN (
     SELECT id::text FROM shops WHERE owner_id::text = v_uid_t
   );

  RETURN jsonb_build_object(
    'shops_count',    v_shops,
    'products_count', v_products,
    'sales_count',    v_sales,
    'clients_count',  v_clients
  );
END $fn$;

REVOKE ALL ON FUNCTION get_user_summary(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_user_summary(UUID) TO authenticated;
