-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_058_reset_with_partners.sql
--
-- Étend `_purge_shop_dependents` pour supprimer aussi les emplacements
-- `type='partner'` et `type='warehouse'` rattachés aux owner_id des
-- boutiques visées par le reset.
--
-- Bug d'origine : ces locations ont `shop_id = NULL` (Fortress les scope
-- par `owner_id`, pas par shop), donc le filtre `WHERE shop_id IN (...)`
-- les ignorait. Conséquence : après "Réinitialiser cette boutique" depuis
-- un device, les partenaires restaient en base et réapparaissaient sur
-- les autres devices via la sync.
--
-- Cette migration ne change pas la signature de `reset_shop_data`,
-- `delete_user_account` ou `reset_all_data` — uniquement le helper
-- partagé. Idempotente, peut être réappliquée sans risque.
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
  v_tbl       TEXT;
  v_owner_ids TEXT[];
BEGIN
  IF p_shop_ids IS NULL OR array_length(p_shop_ids, 1) IS NULL THEN
    RETURN;
  END IF;

  -- Collecter les owner_id distincts des boutiques visées. On les utilise
  -- pour purger les partenaires/warehouses owner-scoped (shop_id NULL).
  BEGIN
    SELECT ARRAY(
      SELECT DISTINCT owner_id::text
      FROM shops
      WHERE id::text = ANY(p_shop_ids) AND owner_id IS NOT NULL
    ) INTO v_owner_ids;
  EXCEPTION
    WHEN OTHERS THEN v_owner_ids := ARRAY[]::TEXT[];
  END;

  -- Niveau 1 : stock_transfers AVANT les locations (FK ON DELETE RESTRICT).
  -- Étendu pour couvrir les transferts qui touchent partenaires/warehouses
  -- des owners visés (sinon DELETE locations échouerait sur FK).
  BEGIN
    EXECUTE format(
      $sql$DELETE FROM stock_transfers
            WHERE from_location_id::text IN (
              SELECT id::text FROM stock_locations
               WHERE shop_id::text = ANY(%L::text[])
                  OR (owner_id::text = ANY(%L::text[])
                      AND type IN ('partner', 'warehouse')))
               OR to_location_id::text IN (
              SELECT id::text FROM stock_locations
               WHERE shop_id::text = ANY(%L::text[])
                  OR (owner_id::text = ANY(%L::text[])
                      AND type IN ('partner', 'warehouse')))$sql$,
      p_shop_ids, v_owner_ids, p_shop_ids, v_owner_ids);
  EXCEPTION
    WHEN undefined_table THEN NULL;
    WHEN undefined_column THEN NULL;
  END;

  -- Niveau 1bis : delivery_transfers (cf. hotfix_049/050) sont scopés
  -- par shop_id direct, pas besoin de la branche owner.
  BEGIN
    EXECUTE format(
      'DELETE FROM delivery_transfers WHERE shop_id::text = ANY(%L::text[])',
      p_shop_ids);
  EXCEPTION
    WHEN undefined_table THEN NULL;
    WHEN undefined_column THEN NULL;
  END;

  -- Niveau 2 : stock_levels des PARTENAIRES (shop_id NULL → exclus du
  -- filtre par shop_id). Doit passer AVANT la suppression des locations
  -- partenaires (le ON DELETE CASCADE le ferait aussi mais on est
  -- explicite pour être robuste si la FK manque).
  IF array_length(v_owner_ids, 1) IS NOT NULL THEN
    BEGIN
      EXECUTE format(
        $sql$DELETE FROM stock_levels
              WHERE location_id IN (
                SELECT id FROM stock_locations
                 WHERE owner_id::text = ANY(%L::text[])
                   AND type IN ('partner', 'warehouse'))$sql$,
        v_owner_ids);
    EXCEPTION
      WHEN undefined_table THEN NULL;
      WHEN undefined_column THEN NULL;
    END;
  END IF;

  -- Niveau 3 : tables qui ont une colonne shop_id (FK vers shops)
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

  -- Niveau 3bis : suppression des locations PARTENAIRES/WAREHOUSE
  -- (shop_id NULL, ratachées via owner_id). À faire APRÈS la purge
  -- des stock_levels et stock_transfers qui les référencent.
  IF array_length(v_owner_ids, 1) IS NOT NULL THEN
    BEGIN
      EXECUTE format(
        $sql$DELETE FROM stock_locations
              WHERE owner_id::text = ANY(%L::text[])
                AND type IN ('partner', 'warehouse')$sql$,
        v_owner_ids);
    EXCEPTION
      WHEN undefined_table THEN NULL;
      WHEN undefined_column THEN NULL;
    END;
  END IF;

  -- Niveau 4 : tables avec store_id (legacy naming)
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

  -- shop_memberships par shop_id
  BEGIN
    EXECUTE format(
      'DELETE FROM shop_memberships WHERE shop_id::text = ANY(%L::text[])',
      p_shop_ids);
  EXCEPTION
    WHEN undefined_table THEN NULL;
  END;

  -- activity_logs liés aux boutiques
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
