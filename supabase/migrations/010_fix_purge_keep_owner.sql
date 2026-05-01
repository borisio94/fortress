-- =============================================================================
-- 010 — Fix _purge_shop_dependents : ne pas supprimer le owner
--
-- Cause : hotfix_019_purge_complete.sql définit `_purge_shop_dependents()`
-- qui fait `DELETE FROM shop_memberships WHERE shop_id = ...` sans exclure
-- l'owner. Mais hotfix_025_is_owner_column.sql a installé un trigger
-- `trg_protect_owner_delete` qui REFUSE de supprimer la ligne du owner
-- tant que la boutique existe → "Impossible de retirer le propriétaire de la
-- boutique" (erreur 42501) lors de reset_shop_data().
--
-- Fix : exclure les owners du DELETE.
--   - Pour `reset_shop_data` : la boutique reste, donc on garde l'owner. ✅
--   - Pour `delete_user_account` / `reset_all_data` : ces RPCs font un
--     `DELETE FROM shops` ensuite, qui déclenche la cascade et supprime
--     les owners restants proprement (le trigger laisse passer car la
--     boutique n'existe plus à ce moment-là). ✅
--
-- Idempotente.
-- =============================================================================

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

  -- shop_memberships : SUPPRIMER UNIQUEMENT LES NON-OWNERS.
  -- Le trigger trg_protect_owner_delete (hotfix_025) bloque la suppression
  -- d'une ligne owner tant que la boutique existe. Pour reset_shop_data on
  -- veut garder le owner. Pour delete_user_account / reset_all_data qui
  -- font ensuite `DELETE FROM shops`, la cascade s'occupe des owners restants
  -- (le trigger laisse passer car la boutique n'existe plus).
  BEGIN
    EXECUTE format(
      'DELETE FROM shop_memberships
        WHERE shop_id::text = ANY(%L::text[])
          AND COALESCE(is_owner, false) = false',
      p_shop_ids);
  EXCEPTION
    WHEN undefined_table THEN NULL;
    WHEN undefined_column THEN
      -- Fallback si la colonne is_owner n'existe pas (hotfix_025 non appliqué).
      EXECUTE format(
        'DELETE FROM shop_memberships
          WHERE shop_id::text = ANY(%L::text[])
            AND role <> ''owner''',
        p_shop_ids);
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
-- Pas de GRANT public — uniquement appelée depuis les RPCs SECURITY DEFINER.
