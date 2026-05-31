-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_098_delete_account_no_raise.sql
--
-- Bug visible : depuis l'interface super-admin, « Supprimer le compte » échoue
-- avec « Compte partiellement supprimé : auth.users intact. Privilèges
-- insuffisants. » et — pire — RIEN n'est supprimé.
--
-- Cause :
--   delete_user_account (hotfix_036) purge toutes les données métier PUIS tente
--   un DELETE FROM auth.users via _purge_auth_user (hotfix_022). Sur Supabase
--   Cloud, le rôle `postgres` (sous lequel tourne la fonction SECURITY DEFINER)
--   n'a PAS le droit de supprimer dans auth.users → _purge_auth_user renvoie
--   false. La fonction faisait alors `RAISE EXCEPTION`, ce qui annule TOUTE la
--   transaction (rollback) : la purge des données est elle aussi perdue.
--   Résultat : le compte reste 100 % intact.
--
-- C'est exactement la limite documentée dans l'edge function reset-platform :
--   seule la service_role (auth.admin.deleteUser) peut purger auth.users.
--
-- Correctif :
--   delete_user_account ne fait PLUS de RAISE quand auth.users n'a pas pu être
--   supprimé. Elle COMMIT la purge des données et retourne `auth_deleted: false`
--   dans son JSONB. Le client (super-admin ET self-delete) bascule alors sur
--   l'edge function `reset-platform` mode `delete-user` qui supprime auth.users
--   via la service_role — fallback garanti, même schéma que reset_all_data.
--
-- Idempotent : DROP + CREATE. Aucune autre fonction touchée.
-- ════════════════════════════════════════════════════════════════════════════

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

  -- 9. auth.users de l'admin (en dernier — supprime aussi la session).
  --    Sur Supabase Cloud ce DELETE échoue souvent (postgres n'a pas le droit
  --    sur auth.users) → _purge_auth_user renvoie false. On NE FAIT PLUS de
  --    RAISE : cela annulerait toute la purge ci-dessus. On committe et on
  --    signale `auth_deleted: false` pour que le client bascule sur l'edge
  --    function reset-platform (service_role) qui terminera le travail.
  BEGIN
    v_auth_deleted := public._purge_auth_user(p_user_id);
  EXCEPTION WHEN OTHERS THEN
    v_auth_deleted := false;
    RAISE WARNING '[delete_user_account] purge auth.users % : %', v_uid_t, SQLERRM;
  END;

  RETURN jsonb_build_object(
    'user_id', v_uid_t,
    'auth_deleted', COALESCE(v_auth_deleted, false),
    'cascaded_employees', v_deleted_employees,
    'shops_deleted', COALESCE(array_length(v_shops, 1), 0)
  );
END $del_acc$;

ALTER FUNCTION public.delete_user_account(UUID) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.delete_user_account(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_user_account(UUID) TO authenticated;

NOTIFY pgrst, 'reload schema';
