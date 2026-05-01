-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_019_purge_complete.sql
--
-- Réécrit les 3 RPCs de purge pour cascader correctement sur TOUTES les
-- tables liées aux boutiques (stock_*, suppliers, incidents, etc.) avant
-- de supprimer shops/profiles.
--
-- Bug d'origine : 23503 foreign key violation sur stock_transfers,
-- stock_movements, etc. quand on tentait DELETE FROM shops.
--
-- Casts ::text systématiques pour rétrocompat avec shop_memberships.user_id
-- et .shop_id stockés en TEXT plutôt qu'UUID.
--
-- Chaque DELETE est protégé par BEGIN/EXCEPTION/END pour ignorer "table
-- inexistante" / "colonne inexistante" → fonctionne quel que soit le
-- sous-ensemble de tables effectivement présentes dans la base.
-- ════════════════════════════════════════════════════════════════════════════

-- ════════════════════════════════════════════════════════════════════════════
-- Fonction helper : purge toutes les tables dépendantes d'un ensemble de
-- boutiques (passées en TEXT[]). Idempotente, tolère les tables absentes.
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public._purge_shop_dependents(p_shop_ids TEXT[])
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $purge$
DECLARE
  v_tables_with_shop_id   TEXT[] := ARRAY[
    'stock_movements', 'stock_levels', 'stock_arrivals',
    'receptions', 'purchase_orders', 'incidents',
    'expenses', 'client_returns', 'suppliers',
    'categories', 'brands', 'units',
    'pending_invitations', 'notifications', 'orders',
    'stock_locations'
  ];
  v_tables_with_store_id  TEXT[] := ARRAY[
    'products', 'clients'
  ];
  v_tbl TEXT;
BEGIN
  IF p_shop_ids IS NULL OR array_length(p_shop_ids, 1) IS NULL THEN
    RETURN;
  END IF;

  -- Niveau 1 : stock_transfers dépend de stock_locations → en premier
  BEGIN
    EXECUTE format(
      $sql$DELETE FROM stock_transfers
            WHERE from_location_id::text IN (
              SELECT id::text FROM stock_locations
               WHERE shop_id::text = ANY(%L::text[]))
               OR to_location_id::text IN (
              SELECT id::text FROM stock_locations
               WHERE shop_id::text = ANY(%L::text[]))$sql$,
      p_shop_ids, p_shop_ids);
  EXCEPTION
    WHEN undefined_table THEN NULL;
    WHEN undefined_column THEN NULL;
  END;

  -- Niveau 2 : tables qui ont une colonne shop_id (FK vers shops)
  FOREACH v_tbl IN ARRAY v_tables_with_shop_id LOOP
    BEGIN
      EXECUTE format(
        'DELETE FROM %I WHERE shop_id::text = ANY(%L::text[])',
        v_tbl, p_shop_ids);
    EXCEPTION
      WHEN undefined_table THEN NULL;
      WHEN undefined_column THEN NULL;
    END;
  END LOOP;

  -- Niveau 3 : tables avec store_id (legacy naming)
  FOREACH v_tbl IN ARRAY v_tables_with_store_id LOOP
    BEGIN
      EXECUTE format(
        'DELETE FROM %I WHERE store_id::text = ANY(%L::text[])',
        v_tbl, p_shop_ids);
    EXCEPTION
      WHEN undefined_table THEN NULL;
      WHEN undefined_column THEN NULL;
    END;
  END LOOP;

  -- shop_memberships par shop_id (les memberships par user_id sont
  -- supprimés ailleurs)
  BEGIN
    EXECUTE format(
      'DELETE FROM shop_memberships WHERE shop_id::text = ANY(%L::text[])',
      p_shop_ids);
  EXCEPTION
    WHEN undefined_table THEN NULL;
  END;

  -- activity_logs liés aux boutiques (best effort, peut référencer shop_id
  -- nullable selon le schéma)
  BEGIN
    EXECUTE format(
      'DELETE FROM activity_logs WHERE shop_id::text = ANY(%L::text[])',
      p_shop_ids);
  EXCEPTION
    WHEN undefined_table THEN NULL;
    WHEN undefined_column THEN NULL;
  END;
END $purge$;

REVOKE ALL ON FUNCTION public._purge_shop_dependents(TEXT[]) FROM PUBLIC;
-- Pas de GRANT public — uniquement appelée depuis les RPCs SECURITY DEFINER

-- ════════════════════════════════════════════════════════════════════════════
-- delete_user_account(UUID) — purge complète d'un compte
-- ════════════════════════════════════════════════════════════════════════════
DROP FUNCTION IF EXISTS public.delete_user_account(UUID);
CREATE FUNCTION public.delete_user_account(p_user_id UUID)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER
SET row_security = off
SET search_path = public, pg_temp
AS $del_acc$
DECLARE
  v_is_sa  BOOLEAN;
  v_email  TEXT;
  v_name   TEXT;
  v_uid_t  TEXT := p_user_id::text;
  v_shops  TEXT[];
BEGIN
  -- Garde
  SELECT COALESCE(is_super_admin, false) INTO v_is_sa
    FROM profiles WHERE id::text = auth.uid()::text;

  IF NOT v_is_sa AND v_uid_t <> auth.uid()::text THEN
    RAISE EXCEPTION 'Non autorisé : vous ne pouvez supprimer que votre propre compte';
  END IF;

  SELECT email, name INTO v_email, v_name
    FROM profiles WHERE id::text = v_uid_t;

  -- Récupérer les boutiques possédées
  SELECT ARRAY(SELECT id::text FROM shops WHERE owner_id::text = v_uid_t)
    INTO v_shops;

  -- 1. Purger toutes les dépendances des boutiques de l'utilisateur
  PERFORM public._purge_shop_dependents(v_shops);

  -- 2. Supprimer les boutiques elles-mêmes
  DELETE FROM shops WHERE owner_id::text = v_uid_t;

  -- 3. Données liées directement à l'utilisateur
  BEGIN
    DELETE FROM subscriptions WHERE user_id::text = v_uid_t;
  EXCEPTION WHEN undefined_table THEN NULL;
  END;

  BEGIN
    DELETE FROM shop_memberships WHERE user_id::text = v_uid_t;
  EXCEPTION WHEN undefined_table THEN NULL;
  END;

  BEGIN
    DELETE FROM pending_invitations WHERE invited_by::text = v_uid_t
                                       OR email = v_email;
  EXCEPTION
    WHEN undefined_table THEN NULL;
    WHEN undefined_column THEN NULL;
  END;

  -- 4. Profile
  DELETE FROM profiles WHERE id::text = v_uid_t;

  -- 5. Log
  INSERT INTO activity_logs (
    actor_id, actor_email, action, target_type, target_id, target_label, details
  )
  VALUES (
    auth.uid(),
    (SELECT email FROM auth.users WHERE id::text = auth.uid()::text),
    CASE WHEN auth.uid()::text = v_uid_t THEN 'account_deleted' ELSE 'user_deleted' END,
    'user', v_uid_t, v_name,
    jsonb_build_object('email', v_email, 'by_super_admin', v_is_sa)
  );

  -- 6. auth.users en dernier
  BEGIN
    DELETE FROM auth.users WHERE id = p_user_id;
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  RETURN p_user_id;
END $del_acc$;

-- Privilèges max pour pouvoir supprimer dans auth.users
ALTER FUNCTION public.delete_user_account(UUID) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.delete_user_account(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_user_account(UUID) TO authenticated;

-- ════════════════════════════════════════════════════════════════════════════
-- reset_shop_data(UUID) — vider une boutique sans la supprimer
-- ════════════════════════════════════════════════════════════════════════════
DROP FUNCTION IF EXISTS public.reset_shop_data(UUID);
CREATE FUNCTION public.reset_shop_data(p_shop_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET row_security = off
SET search_path = public, pg_temp
AS $reset_shop$
DECLARE
  v_owner_t TEXT;
  v_name    TEXT;
  v_shop_t  TEXT := p_shop_id::text;
BEGIN
  SELECT owner_id::text, name INTO v_owner_t, v_name
    FROM shops WHERE id::text = v_shop_t;

  IF v_owner_t IS NULL THEN
    RAISE EXCEPTION 'Boutique introuvable';
  END IF;

  IF v_owner_t <> auth.uid()::text AND NOT EXISTS (
    SELECT 1 FROM profiles
     WHERE id::text = auth.uid()::text AND is_super_admin = true
  ) THEN
    RAISE EXCEPTION 'Non autorisé : propriétaire ou super admin requis';
  END IF;

  -- Purger toutes les dépendances de cette boutique
  PERFORM public._purge_shop_dependents(ARRAY[v_shop_t]);

  INSERT INTO activity_logs (
    actor_id, actor_email, action, target_type,
    target_id, target_label, shop_id, details
  )
  VALUES (
    auth.uid(),
    (SELECT email FROM auth.users WHERE id::text = auth.uid()::text),
    'shop_reset', 'shop', v_shop_t, v_name, p_shop_id,
    jsonb_build_object('at', now())
  );

  RETURN jsonb_build_object('shop_id', v_shop_t, 'reset', true);
END $reset_shop$;

REVOKE ALL ON FUNCTION public.reset_shop_data(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reset_shop_data(UUID) TO authenticated;

-- ════════════════════════════════════════════════════════════════════════════
-- reset_all_data() — purge plateforme (super admin uniquement)
-- ════════════════════════════════════════════════════════════════════════════
DROP FUNCTION IF EXISTS public.reset_all_data();
CREATE FUNCTION public.reset_all_data()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET row_security = off
SET search_path = public, pg_temp
AS $reset_all$
DECLARE
  v_deleted_profiles INT := 0;
  v_deleted_auth     INT := 0;
  v_auth_error       TEXT := NULL;
  v_all_shops        TEXT[];
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM profiles
    WHERE id::text = auth.uid()::text AND is_super_admin = true
  ) THEN
    RAISE EXCEPTION 'Seul un super admin peut exécuter cette opération';
  END IF;

  -- Récupérer toutes les boutiques (de tout le monde)
  SELECT ARRAY(SELECT id::text FROM shops) INTO v_all_shops;

  -- Purger toutes les dépendances
  PERFORM public._purge_shop_dependents(v_all_shops);

  -- Supprimer les boutiques
  DELETE FROM shops;

  -- Memberships restants (sécurité — devrait être vide après purge)
  BEGIN DELETE FROM shop_memberships;
  EXCEPTION WHEN undefined_table THEN NULL; END;

  BEGIN DELETE FROM subscriptions;
  EXCEPTION WHEN undefined_table THEN NULL; END;

  BEGIN DELETE FROM pending_invitations;
  EXCEPTION WHEN undefined_table THEN NULL; END;

  -- Profiles non super-admin
  WITH d AS (
    DELETE FROM profiles
    WHERE COALESCE(is_super_admin, false) = false
    RETURNING 1
  )
  SELECT COUNT(*) INTO v_deleted_profiles FROM d;

  -- auth.users non super-admin
  BEGIN
    WITH d AS (
      DELETE FROM auth.users
      WHERE id NOT IN (SELECT id FROM profiles WHERE is_super_admin = true)
      RETURNING 1
    )
    SELECT COUNT(*) INTO v_deleted_auth FROM d;
  EXCEPTION
    WHEN insufficient_privilege THEN
      v_auth_error := 'insufficient_privilege';
      RAISE WARNING
        '[reset_all_data] Impossible de supprimer auth.users — privilèges manquants. '
        'Changez l''OWNER de la fonction à postgres ou utilisez une Edge Function.';
    WHEN OTHERS THEN
      v_auth_error := SQLERRM;
      RAISE WARNING '[reset_all_data] Erreur auth.users : %', SQLERRM;
  END;

  INSERT INTO activity_logs (
    actor_id, actor_email, action, target_type, details
  )
  VALUES (
    auth.uid(),
    (SELECT email FROM auth.users WHERE id::text = auth.uid()::text),
    'platform_reset', 'platform',
    jsonb_build_object(
      'at', now(),
      'deleted_profiles', v_deleted_profiles,
      'deleted_auth_users', v_deleted_auth,
      'auth_error', v_auth_error
    )
  );

  RETURN jsonb_build_object(
    'deleted_profiles',   v_deleted_profiles,
    'deleted_auth_users', v_deleted_auth,
    'auth_error',         v_auth_error
  );
END $reset_all$;

ALTER FUNCTION public.reset_all_data() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.reset_all_data() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reset_all_data() TO authenticated;

-- Grant DELETE sur auth.users si possible
DO $grant_auth$
BEGIN
  GRANT DELETE ON auth.users TO postgres;
EXCEPTION WHEN insufficient_privilege THEN NULL;
END $grant_auth$;
