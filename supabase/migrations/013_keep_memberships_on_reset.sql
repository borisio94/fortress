-- =============================================================================
-- 013 — reset_shop_data ne doit plus supprimer les shop_memberships
--
-- Bug : après `reset_shop_data`, les memberships admin/user de la boutique
-- étaient supprimés (cf. _purge_shop_dependents). Conséquences :
--   1. Les employés perdaient leur accès à la boutique.
--   2. À la reconnexion, l'app les redirigeait vers la page d'abonnement
--      (qui est réservée au owner) car ils n'avaient plus de boutique liée.
--
-- Fix :
--   1. `_purge_shop_dependents` ne touche PLUS aux memberships.
--      → reset_shop_data garde TOUS les membres intacts (owner + admins + users).
--   2. La FK `shop_memberships.shop_id → shops.id` est mise en
--      `ON DELETE CASCADE` (idempotent). Ainsi les RPCs qui suppriment
--      vraiment la boutique (`delete_user_account`, `reset_all_data`)
--      voient leurs memberships disparaître automatiquement par cascade —
--      pas besoin de DELETE explicite.
--
-- Idempotente.
-- =============================================================================

-- ── 1. _purge_shop_dependents sans DELETE memberships ─────────────────────
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

  -- ⚠️ shop_memberships : NE PLUS LES SUPPRIMER ICI.
  -- Pour reset_shop_data : la boutique reste → les membres doivent rester.
  -- Pour delete_user_account / reset_all_data : DELETE shops cascade
  -- automatiquement (cf. ALTER FK plus bas dans cette migration).

  -- activity_logs liés aux boutiques (best effort).
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

-- ── 2. FK shop_memberships → shops en ON DELETE CASCADE ───────────────────
-- Si une autre contrainte FK existe déjà (sans cascade), on la drop puis on
-- la recrée avec CASCADE. Si elle n'existe pas, on la crée. Idempotent.
DO $cascade$
DECLARE
  v_conname TEXT;
BEGIN
  SELECT c.conname INTO v_conname
  FROM   pg_constraint c
  WHERE  c.conrelid  = 'public.shop_memberships'::regclass
    AND  c.contype   = 'f'
    AND  c.confrelid = 'public.shops'::regclass
  LIMIT  1;

  IF v_conname IS NOT NULL THEN
    EXECUTE format(
      'ALTER TABLE public.shop_memberships DROP CONSTRAINT %I',
      v_conname);
  END IF;

  ALTER TABLE public.shop_memberships
    ADD CONSTRAINT shop_memberships_shop_id_fkey
    FOREIGN KEY (shop_id) REFERENCES public.shops(id)
    ON DELETE CASCADE;
EXCEPTION
  WHEN undefined_table THEN NULL;
  WHEN undefined_column THEN NULL;
END $cascade$;
