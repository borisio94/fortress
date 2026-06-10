-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_102_shop_backups.sql  —  Sauvegarde APPLICATIVE par boutique (Étape A)
--
-- Objectif : permettre, depuis le super-admin, d'activer/désactiver une
-- sauvegarde automatique des données d'une boutique, de la sauvegarder à la
-- demande, et de la RESTAURER. Indépendant du plan d'abonnement du client.
--
-- Cette migration pose le socle SQL :
--   1. shops.backup_enabled (bool, défaut TRUE → toutes les boutiques
--      protégées par défaut ; le SA peut désactiver au cas par cas).
--   2. Table shop_backups : métadonnées des snapshots (1 ligne / snapshot).
--   3. RPC export_shop_snapshot(shop_id)  → jsonb complet des données.
--   4. RPC restore_shop_snapshot(shop_id, payload)  → réécrit les données.
--   5. RPC set_shop_backup_enabled(shop_id, enabled).
--   6. Bucket Storage privé 'shop-backups' (l'upload/download réel se fait
--      via l'edge function shop-backup en service_role — Étape B).
--
-- Le contenu d'un snapshot CALQUE _purge_shop_dependents (hotfix_058) : mêmes
-- tables, mêmes colonnes de scoping → aucune table oubliée, symétrie avec le
-- reset. jsonb_populate_recordset reconstruit les lignes au restore sans
-- mapping manuel (robuste aux ajouts de colonnes).
--
-- Idempotent. Aucune donnée touchée à l'application.
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1. Flag par boutique ────────────────────────────────────────────────────
ALTER TABLE public.shops
  ADD COLUMN IF NOT EXISTS backup_enabled boolean NOT NULL DEFAULT true;

-- ── 2. Table des snapshots ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.shop_backups (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id      text NOT NULL,
  storage_path text,                       -- chemin dans le bucket shop-backups
  created_at   timestamptz NOT NULL DEFAULT now(),
  size_bytes   bigint,
  row_counts   jsonb,                      -- {"products":124,"orders":540,...}
  status       text NOT NULL DEFAULT 'completed',  -- completed | failed | running
  is_auto      boolean NOT NULL DEFAULT true,      -- cron quotidien vs manuel
  created_by   uuid,
  error        text
);
CREATE INDEX IF NOT EXISTS shop_backups_shop_idx
  ON public.shop_backups (shop_id, created_at DESC);

ALTER TABLE public.shop_backups ENABLE ROW LEVEL SECURITY;

-- SA : tout. Owner/membre : lecture de SES snapshots uniquement.
DROP POLICY IF EXISTS shop_backups_sa_all ON public.shop_backups;
CREATE POLICY shop_backups_sa_all ON public.shop_backups
  FOR ALL TO authenticated
  USING       (public._is_super_admin())
  WITH CHECK  (public._is_super_admin());

DROP POLICY IF EXISTS shop_backups_member_read ON public.shop_backups;
CREATE POLICY shop_backups_member_read ON public.shop_backups
  FOR SELECT TO authenticated
  USING (public._is_shop_member(shop_id));

-- ── 3. Export : snapshot jsonb complet d'une boutique ───────────────────────
-- Autorisé : super-admin OU membre actif de la boutique.
DROP FUNCTION IF EXISTS public.export_shop_snapshot(text);
CREATE FUNCTION public.export_shop_snapshot(p_shop_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $export$
DECLARE
  v_store_tables text[] := ARRAY['products','clients'];
  v_shop_tables  text[] := ARRAY[
    'categories','brands','units','suppliers','stock_locations',
    'orders','expenses','incidents','client_returns',
    'stock_movements','stock_levels','stock_arrivals',
    'receptions','purchase_orders','delivery_transfers',
    'partner_ledger_entries','pending_invitations','notifications'
  ];
  v_tbl  text;
  v_rows jsonb;
  v_data jsonb := '{}'::jsonb;
BEGIN
  -- Autorisé : super-admin, membre actif de la boutique, OU la service_role
  -- (edge function shop-backup / cron quotidien — pas de JWT utilisateur).
  IF NOT (public._is_super_admin()
          OR public._is_shop_member(p_shop_id)
          OR COALESCE(current_setting('request.jwt.claims', true)::jsonb ->> 'role', '')
             = 'service_role') THEN
    RAISE EXCEPTION 'forbidden: acces sauvegarde refuse' USING ERRCODE = '42501';
  END IF;

  -- Ligne boutique elle-même (référence ; non réinsérée au restore).
  BEGIN
    SELECT to_jsonb(s) INTO v_rows FROM shops s WHERE s.id::text = p_shop_id;
    v_data := jsonb_set(v_data, ARRAY['shop'], COALESCE(v_rows, 'null'::jsonb));
  EXCEPTION WHEN undefined_table THEN NULL; WHEN undefined_column THEN NULL; END;

  FOREACH v_tbl IN ARRAY v_store_tables LOOP
    BEGIN
      EXECUTE format(
        'SELECT COALESCE(jsonb_agg(t), ''[]''::jsonb) FROM %I t WHERE store_id::text = %L',
        v_tbl, p_shop_id) INTO v_rows;
      v_data := jsonb_set(v_data, ARRAY[v_tbl], COALESCE(v_rows, '[]'::jsonb));
    EXCEPTION WHEN undefined_table THEN NULL; WHEN undefined_column THEN NULL; END;
  END LOOP;

  FOREACH v_tbl IN ARRAY v_shop_tables LOOP
    BEGIN
      EXECUTE format(
        'SELECT COALESCE(jsonb_agg(t), ''[]''::jsonb) FROM %I t WHERE shop_id::text = %L',
        v_tbl, p_shop_id) INTO v_rows;
      v_data := jsonb_set(v_data, ARRAY[v_tbl], COALESCE(v_rows, '[]'::jsonb));
    EXCEPTION WHEN undefined_table THEN NULL; WHEN undefined_column THEN NULL; END;
  END LOOP;

  -- Tables ENFANTS (scopées via parent).
  BEGIN
    EXECUTE format(
      'SELECT COALESCE(jsonb_agg(t), ''[]''::jsonb) FROM purchase_order_items t '
      'WHERE order_id::text IN (SELECT id::text FROM purchase_orders WHERE shop_id::text = %L)',
      p_shop_id) INTO v_rows;
    v_data := jsonb_set(v_data, ARRAY['purchase_order_items'], COALESCE(v_rows, '[]'::jsonb));
  EXCEPTION WHEN undefined_table THEN NULL; WHEN undefined_column THEN NULL; END;
  BEGIN
    EXECUTE format(
      'SELECT COALESCE(jsonb_agg(t), ''[]''::jsonb) FROM reception_items t '
      'WHERE reception_id::text IN (SELECT id::text FROM receptions WHERE shop_id::text = %L)',
      p_shop_id) INTO v_rows;
    v_data := jsonb_set(v_data, ARRAY['reception_items'], COALESCE(v_rows, '[]'::jsonb));
  EXCEPTION WHEN undefined_table THEN NULL; WHEN undefined_column THEN NULL; END;

  RETURN jsonb_build_object(
    'version',     1,
    'shop_id',     p_shop_id,
    'exported_at', now(),
    'tables',      v_data
  );
END $export$;

REVOKE ALL ON FUNCTION public.export_shop_snapshot(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.export_shop_snapshot(text) TO authenticated;

-- ── 4. Restore : réécrit les données de la boutique depuis un snapshot ──────
-- RÉSERVÉ super-admin. Atomique (toute erreur de données → rollback complet,
-- on ne catch QUE undefined_table/column structurels).
-- Ordre : on supprime les données existantes de la boutique (enfants→parents),
-- puis on réinsère (parents→enfants) via jsonb_populate_recordset.
DROP FUNCTION IF EXISTS public.restore_shop_snapshot(text, jsonb);
CREATE FUNCTION public.restore_shop_snapshot(p_shop_id text, p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $restore$
DECLARE
  -- Suppression : enfants d'abord, puis le reste (FK-safe).
  v_del_child  text[] := ARRAY['purchase_order_items','reception_items'];
  v_del_shop   text[] := ARRAY[
    'notifications','pending_invitations','partner_ledger_entries',
    'delivery_transfers','purchase_orders','receptions',
    'stock_arrivals','stock_levels','stock_movements',
    'client_returns','incidents','expenses','orders',
    'stock_locations','suppliers','units','brands','categories'
  ];
  v_del_store  text[] := ARRAY['products','clients'];
  -- Réinsertion : parents d'abord.
  v_ins_ref    text[] := ARRAY['categories','brands','units','suppliers','stock_locations'];
  v_ins_core   text[] := ARRAY['products','clients'];
  v_ins_shop   text[] := ARRAY[
    'orders','expenses','incidents','client_returns',
    'stock_movements','stock_levels','stock_arrivals',
    'receptions','purchase_orders','delivery_transfers',
    'partner_ledger_entries','pending_invitations','notifications'
  ];
  v_ins_child  text[] := ARRAY['purchase_order_items','reception_items'];
  v_tables jsonb := p_payload->'tables';
  v_tbl text;
  v_counts jsonb := '{}'::jsonb;
  v_n bigint;
BEGIN
  -- Réservé super-admin OU service_role (edge function shop-backup).
  IF NOT (public._is_super_admin()
          OR COALESCE(current_setting('request.jwt.claims', true)::jsonb ->> 'role', '')
             = 'service_role') THEN
    RAISE EXCEPTION 'forbidden: restauration reservee au super-admin' USING ERRCODE = '42501';
  END IF;
  IF v_tables IS NULL THEN
    RAISE EXCEPTION 'payload invalide (tables manquant)' USING ERRCODE = 'P0001';
  END IF;
  IF COALESCE(p_payload->>'shop_id','') <> p_shop_id THEN
    RAISE EXCEPTION 'shop_id du snapshot != cible' USING ERRCODE = 'P0001';
  END IF;

  -- ── Purge enfants ─────────────────────────────────────────────────────────
  BEGIN
    EXECUTE format('DELETE FROM purchase_order_items WHERE order_id::text IN '
      '(SELECT id::text FROM purchase_orders WHERE shop_id::text = %L)', p_shop_id);
  EXCEPTION WHEN undefined_table THEN NULL; WHEN undefined_column THEN NULL; END;
  BEGIN
    EXECUTE format('DELETE FROM reception_items WHERE reception_id::text IN '
      '(SELECT id::text FROM receptions WHERE shop_id::text = %L)', p_shop_id);
  EXCEPTION WHEN undefined_table THEN NULL; WHEN undefined_column THEN NULL; END;

  -- ── Purge tables shop_id puis store_id ────────────────────────────────────
  FOREACH v_tbl IN ARRAY v_del_shop LOOP
    BEGIN
      EXECUTE format('DELETE FROM %I WHERE shop_id::text = %L', v_tbl, p_shop_id);
    EXCEPTION WHEN undefined_table THEN NULL; WHEN undefined_column THEN NULL; END;
  END LOOP;
  FOREACH v_tbl IN ARRAY v_del_store LOOP
    BEGIN
      EXECUTE format('DELETE FROM %I WHERE store_id::text = %L', v_tbl, p_shop_id);
    EXCEPTION WHEN undefined_table THEN NULL; WHEN undefined_column THEN NULL; END;
  END LOOP;

  -- ── Réinsertion (parents → enfants) ───────────────────────────────────────
  FOREACH v_tbl IN ARRAY (v_ins_ref || v_ins_core || v_ins_shop || v_ins_child) LOOP
    IF v_tables ? v_tbl AND jsonb_typeof(v_tables->v_tbl) = 'array'
       AND jsonb_array_length(v_tables->v_tbl) > 0 THEN
      BEGIN
        EXECUTE format(
          'INSERT INTO %I SELECT * FROM jsonb_populate_recordset(NULL::%I, $1)',
          v_tbl, v_tbl) USING (v_tables->v_tbl);
        v_n := jsonb_array_length(v_tables->v_tbl);
        v_counts := jsonb_set(v_counts, ARRAY[v_tbl], to_jsonb(v_n));
      EXCEPTION WHEN undefined_table THEN NULL; WHEN undefined_column THEN NULL; END;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('restored', true, 'shop_id', p_shop_id, 'row_counts', v_counts);
END $restore$;

REVOKE ALL ON FUNCTION public.restore_shop_snapshot(text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.restore_shop_snapshot(text, jsonb) TO authenticated;

-- ── 5. Toggle activé/désactivé (super-admin) ────────────────────────────────
DROP FUNCTION IF EXISTS public.set_shop_backup_enabled(text, boolean);
CREATE FUNCTION public.set_shop_backup_enabled(p_shop_id text, p_enabled boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $toggle$
BEGIN
  IF NOT public._is_super_admin() THEN
    RAISE EXCEPTION 'forbidden: super-admin requis' USING ERRCODE = '42501';
  END IF;
  UPDATE public.shops SET backup_enabled = p_enabled WHERE id::text = p_shop_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'boutique introuvable' USING ERRCODE = 'P0002';
  END IF;
  RETURN jsonb_build_object('shop_id', p_shop_id, 'backup_enabled', p_enabled);
END $toggle$;

REVOKE ALL ON FUNCTION public.set_shop_backup_enabled(text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_shop_backup_enabled(text, boolean) TO authenticated;

-- ── 6. Bucket Storage privé ─────────────────────────────────────────────────
-- L'upload/download réel passe par l'edge function shop-backup (service_role,
-- bypass RLS). Bucket privé, aucune policy publique.
INSERT INTO storage.buckets (id, name, public)
VALUES ('shop-backups', 'shop-backups', false)
ON CONFLICT (id) DO NOTHING;

NOTIFY pgrst, 'reload schema';
