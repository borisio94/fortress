-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_085_products_soft_delete.sql
--
-- Suppression SÉCURISÉE des produits (catalogue) — soft-delete + RPC dédiée.
--
-- Contexte
-- ────────
-- Avant ce hotfix, supprimer un produit passait par `AppDatabase.deleteProduct`
-- → DELETE Supabase direct + tombstone Hive. Trois problèmes :
--   1. Offline-first : un DELETE peut être ressuscité par re-push d'un autre
--      appareil. Le tombstone Hive est local et ne couvre pas tous les paths
--      (sync initial, premier login sur un nouveau device).
--   2. hotfix_083 a posé un trigger BEFORE DELETE qui refuse la suppression
--      quand stock > 0 ou ventes ouvertes — mais c'est binaire (échec brut),
--      sans trace et sans motif. Soft-delete = on garde l'historique + le
--      snapshot du produit pour audit, on documente la décision.
--   3. Aucune trace dans `activity_logs` → impossible d'auditer qui/quand/pourquoi.
--
-- Ce hotfix met en place :
--   • Colonnes `deleted_at`, `deleted_by`, `delete_reason`, `archived_snapshot`
--     sur `products`. Pas de table `variants` séparée dans le schéma —
--     les variantes vivent dans le JSONB `products.variants` (cf.
--     hotfix_083). Le soft-delete du parent est donc suffisant : aucune
--     lecture ne porte sur les variantes isolément.
--   • Index partiels (lectures live + page super-admin).
--   • RLS modifiée pour CACHER les supprimées aux membres et les EXPOSER
--     uniquement au super-admin.
--   • RPC `delete_product(p_product_id, p_user_id, p_reason)` SECURITY DEFINER :
--       — Refus si motif < 10 chars → `motif_required` (P0001).
--       — Refus si l'appelant n'est pas admin/owner du shop →
--         `permission_insuffisante` (42501).
--       — Refus si stock résiduel > 0 (somme sur toutes les locations) →
--         `produit_en_stock` (P0001), DETAIL = qty.
--       — Refus si ≥ 1 commande ouverte (scheduled/processing non-supprimée)
--         référence ce produit (par product_id ou variant_id) →
--         `produit_commandes_ouvertes` (P0001), DETAIL = count.
--       — Snapshot JSONB ({name, sku, price_*, category_id, brand_id,
--         image_url, variants}) → permet d'afficher la fiche dans l'écran
--         super-admin même si la ligne a été corrompue depuis.
--       — UPDATE : deleted_at + deleted_by + delete_reason +
--         archived_snapshot + is_active=FALSE + is_visible_web=FALSE.
--       — Idempotente : 2ᵉ appel retourne {already:true}.
--       — Trace `activity_logs` (action=product_deleted).
--   • RPC `restore_product(p_product_id, p_user_id)` SECURITY DEFINER :
--       — Réservée `_is_super_admin()`.
--       — Désarchive (deleted_at=NULL, ...) MAIS ne touche PAS à is_active
--         ni is_visible_web → le manager doit republier manuellement.
--       — Trace `activity_logs` (action=product_restored).
--
-- ⚠ Le trigger `trg_block_product_delete_with_stock` posé par hotfix_083
--   reste actif comme FILET DE SÉCURITÉ : la RPC fait un UPDATE (pas un
--   DELETE), donc ne déclenche pas le trigger. Le trigger continue de
--   protéger contre les DELETE directs depuis SQL Editor / intégrations
--   tierces.
--
-- Idempotent : ADD COLUMN IF NOT EXISTS, CREATE INDEX IF NOT EXISTS,
-- CREATE OR REPLACE FUNCTION, DROP POLICY IF EXISTS avant CREATE POLICY.
-- Sûr à ré-exécuter.
-- ════════════════════════════════════════════════════════════════════════════

-- ─── 1. Colonnes soft-delete sur products ────────────────────────────────
ALTER TABLE IF EXISTS public.products
  ADD COLUMN IF NOT EXISTS deleted_at        TIMESTAMPTZ;

ALTER TABLE IF EXISTS public.products
  ADD COLUMN IF NOT EXISTS deleted_by        UUID;

ALTER TABLE IF EXISTS public.products
  ADD COLUMN IF NOT EXISTS delete_reason     TEXT;

-- Snapshot complet du produit AU MOMENT de la suppression : préserve une
-- copie même si la ligne est partiellement corrompue ensuite (ex: un
-- realtime UPDATE écraserait certains champs). Lu par l'écran super-admin
-- pour montrer les caractéristiques au moment de la décision.
ALTER TABLE IF EXISTS public.products
  ADD COLUMN IF NOT EXISTS archived_snapshot JSONB;

-- Index partiel : ne porte que sur les lignes vivantes (≈ 99% du temps).
-- L'app filtre `deleted_at IS NULL` côté Hive ET côté RLS → cet index est
-- celui qui sera planifié pour les listes produits.
CREATE INDEX IF NOT EXISTS products_not_deleted_idx
  ON public.products (store_id)
  WHERE deleted_at IS NULL;

-- Index dédié pour la page super-admin "Produits supprimés" — tri par
-- date de suppression desc, scan partiel sur ≪ 1% des lignes.
CREATE INDEX IF NOT EXISTS products_deleted_idx
  ON public.products (deleted_at DESC)
  WHERE deleted_at IS NOT NULL;

-- ─── 2. RLS : cacher les supprimées aux membres, exposer au super-admin ──
-- Les policies historiques (hotfix_041) sont séparées par opération :
-- products_select / products_insert / products_update / products_delete.
-- On REMPLACE uniquement `products_select` pour ajouter le filtre
-- deleted_at, et on AJOUTE `products_select_deleted_sa` pour donner accès
-- aux super-admins. Les autres policies (insert/update/delete) restent
-- inchangées — la RPC delete_product est SECURITY DEFINER et bypass la
-- RLS de toute façon, et un UPDATE direct sur une ligne supprimée n'est
-- pas autorisé puisque la lecture la masque déjà.
DROP POLICY IF EXISTS products_select              ON public.products;
DROP POLICY IF EXISTS products_select_visible      ON public.products;
DROP POLICY IF EXISTS products_select_deleted_sa   ON public.products;

CREATE POLICY products_select_visible ON public.products
  FOR SELECT TO authenticated
  USING (
        deleted_at IS NULL
    AND public._is_shop_member(store_id::text)
  );

CREATE POLICY products_select_deleted_sa ON public.products
  FOR SELECT TO authenticated
  USING (
        deleted_at IS NOT NULL
    AND public._is_super_admin()
  );

-- REPLICA IDENTITY FULL : payload realtime porte la ligne complète, donc
-- l'app reçoit `deleted_at` ET l'old record lors d'un UPDATE → les listes
-- locales peuvent réagir au soft-delete via le canal realtime existant.
-- Idempotent (no-op si déjà FULL).
ALTER TABLE IF EXISTS public.products REPLICA IDENTITY FULL;

-- ─── 3. RPC delete_product ───────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.delete_product(text, uuid, text);

CREATE OR REPLACE FUNCTION public.delete_product(
  p_product_id text,
  p_user_id    uuid,
  p_reason     text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_store_id    text;
  v_name        text;
  v_already     timestamptz;
  v_reason      text := COALESCE(trim(p_reason), '');
  v_variant_ids text[] := ARRAY[]::text[];
  v_stock_total integer := 0;
  v_open_count  integer := 0;
  v_snapshot    jsonb;
BEGIN
  -- ── 1. Motif requis (vérification locale avant tout). ────────────────
  IF length(v_reason) < 10 THEN
    RAISE EXCEPTION 'motif_required'
      USING ERRCODE = 'P0001',
            MESSAGE = 'Motif obligatoire (10 caractères minimum).',
            DETAIL  = jsonb_build_object('code', 'motif_required')::text;
  END IF;

  -- ── 2. Lecture + verrou de la ligne. FOR UPDATE empêche les races (2
  --       onglets qui suppriment au même instant ou une autre RPC qui
  --       mute la ligne entre la lecture et le UPDATE).
  SELECT store_id::text, name, deleted_at
    INTO v_store_id, v_name, v_already
    FROM public.products
   WHERE id = p_product_id
     FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'product_not_found'
      USING ERRCODE = 'P0002',
            MESSAGE = 'Produit introuvable.',
            DETAIL  = jsonb_build_object('code', 'product_not_found',
                                         'product_id', p_product_id)::text;
  END IF;

  -- ── 3. Idempotence : déjà supprimé → no-op silencieux. ───────────────
  IF v_already IS NOT NULL THEN
    RETURN jsonb_build_object(
      'product_id', p_product_id,
      'deleted_at', v_already,
      'already',    true
    );
  END IF;

  -- ── 4. Permission : admin/owner du shop OU super-admin. Le helper
  --       _is_shop_admin (hotfix_024) couvre les 3 cas. La RPC est
  --       SECURITY DEFINER mais auth.uid() reste l'appelant.
  IF NOT public._is_shop_admin(v_store_id) THEN
    RAISE EXCEPTION 'permission_insuffisante'
      USING ERRCODE = '42501',
            MESSAGE = 'Suppression réservée aux administrateurs/propriétaires.',
            DETAIL  = jsonb_build_object('code','permission_insuffisante',
                                         'shop_id', v_store_id)::text;
  END IF;

  -- ── 5. Extraction des variant_ids depuis le JSONB (même pattern que
  --       hotfix_083). Nécessaire pour les checks 6 et 7. ──────────────
  SELECT COALESCE(
    array_agg(DISTINCT (v->>'id'))
      FILTER (WHERE (v->>'id') IS NOT NULL AND length(v->>'id') > 0),
    ARRAY[]::text[]
  )
  INTO v_variant_ids
  FROM jsonb_array_elements(COALESCE(
    (SELECT variants FROM public.products WHERE id = p_product_id),
    '[]'::jsonb)) AS v;

  -- ── 6. Stock résiduel (somme stock_available sur toutes les locations).
  --       Si stock_physical > 0 mais stock_available = 0, on bloque aussi :
  --       il y a quelque chose à reclasser/évacuer avant suppression.
  IF array_length(v_variant_ids, 1) > 0 THEN
    SELECT COALESCE(SUM(GREATEST(stock_available, stock_physical)), 0)
      INTO v_stock_total
      FROM public.stock_levels
     WHERE variant_id = ANY(v_variant_ids);
  END IF;

  IF v_stock_total > 0 THEN
    RAISE EXCEPTION 'produit_en_stock'
      USING ERRCODE = 'P0001',
            MESSAGE = format(
              'Suppression refusée : %s unité(s) en stock à évacuer d''abord.',
              v_stock_total),
            DETAIL  = jsonb_build_object(
              'code',         'produit_en_stock',
              'product_id',   p_product_id,
              'product_name', v_name,
              'stock_total',  v_stock_total
            )::text;
  END IF;

  -- ── 7. Commandes ouvertes (scheduled/processing) NON supprimées qui
  --       référencent le produit. On match items.product_id soit avec
  --       le product_id, soit avec n'importe quel variant_id du produit
  --       (mêmes règles que hotfix_083 et que `AppDatabase.deleteProduct`).
  SELECT COUNT(*)::int
    INTO v_open_count
    FROM public.orders o,
         LATERAL jsonb_array_elements(COALESCE(o.items, '[]'::jsonb)) AS it
   WHERE o.status IN ('scheduled', 'processing')
     AND o.deleted_at IS NULL          -- exclure les commandes soft-deleted (hotfix_084)
     AND (it->>'product_id' = p_product_id
          OR (it->>'product_id' = ANY(v_variant_ids)));

  IF v_open_count > 0 THEN
    RAISE EXCEPTION 'produit_commandes_ouvertes'
      USING ERRCODE = 'P0001',
            MESSAGE = format(
              'Suppression refusée : %s commande(s) ouverte(s) référencent ce produit.',
              v_open_count),
            DETAIL  = jsonb_build_object(
              'code',             'produit_commandes_ouvertes',
              'product_id',       p_product_id,
              'product_name',     v_name,
              'open_orders_count', v_open_count
            )::text;
  END IF;

  -- ── 8. Snapshot complet : préserve les champs utiles à l'affichage
  --       côté écran super-admin si la ligne est altérée par la suite
  --       (realtime, sync). On capture les colonnes communes + le JSONB
  --       variants complet. Le snapshot est figé : il ne suivra pas les
  --       UPDATE postérieurs.
  SELECT jsonb_build_object(
           'id',              p.id,
           'name',            p.name,
           'sku',             p.sku,
           'barcode',         p.barcode,
           'category_id',     p.category_id,
           'brand_id',        p.brand_id,
           'price_sell',      p.price_sell,
           'price_buy',       p.price_buy,
           'is_active',       p.is_active,
           'is_visible_web',  p.is_visible_web,
           'image_url',       p.image_url,
           'variants',        COALESCE(p.variants, '[]'::jsonb),
           'data',            COALESCE(p.data,     '{}'::jsonb)
         )
    INTO v_snapshot
    FROM public.products p
   WHERE id = p_product_id;

  -- ── 9. Soft-delete + cache snapshot + retrait des deux catalogues
  --       (interne is_active + public is_visible_web). La restauration
  --       super-admin ne touchera pas à ces deux flags → republication
  --       manuelle requise.
  UPDATE public.products
     SET deleted_at        = NOW(),
         deleted_by        = p_user_id,
         delete_reason     = v_reason,
         archived_snapshot = v_snapshot,
         is_active         = FALSE,
         is_visible_web    = FALSE
   WHERE id = p_product_id;

  -- ── 10. Trace activity_logs (cohérent avec hotfix_084 pour les ventes).
  INSERT INTO public.activity_logs (
    actor_id, actor_email,
    action, target_type, target_id, target_label,
    shop_id, details, created_at
  )
  SELECT
    auth.uid(),
    (SELECT email FROM auth.users WHERE id = auth.uid()),
    'product_deleted',
    'product',
    p_product_id,
    v_name,
    v_store_id::uuid,
    jsonb_build_object(
      'reason',      v_reason,
      'deleted_by',  p_user_id,
      'stock_total', v_stock_total,
      'snapshot',    v_snapshot
    ),
    NOW();

  RETURN jsonb_build_object(
    'product_id', p_product_id,
    'deleted_at', NOW(),
    'already',    false
  );
END;
$fn$;

ALTER FUNCTION public.delete_product(text, uuid, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.delete_product(text, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_product(text, uuid, text)
  TO authenticated;

-- ─── 4. RPC restore_product (super-admin only) ──────────────────────────
DROP FUNCTION IF EXISTS public.restore_product(text, uuid);

CREATE OR REPLACE FUNCTION public.restore_product(
  p_product_id text,
  p_user_id    uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_was_deleted timestamptz;
  v_store_id    text;
  v_name        text;
BEGIN
  -- ── 1. Garde-fou super-admin. defense-in-depth : la RPC est SECURITY
  --       DEFINER donc sans ce check elle serait callable par tout
  --       authenticated.
  IF NOT public._is_super_admin() THEN
    RAISE EXCEPTION 'permission_insuffisante'
      USING ERRCODE = '42501',
            MESSAGE = 'Restauration réservée au super-admin.',
            DETAIL  = jsonb_build_object('code','permission_insuffisante')::text;
  END IF;

  -- ── 2. Verrou + lecture (FOR UPDATE).
  SELECT deleted_at, store_id::text, name
    INTO v_was_deleted, v_store_id, v_name
    FROM public.products
   WHERE id = p_product_id
     FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'product_not_found'
      USING ERRCODE = 'P0002',
            MESSAGE = 'Produit introuvable.',
            DETAIL  = jsonb_build_object('code','product_not_found',
                                         'product_id', p_product_id)::text;
  END IF;

  -- ── 3. Idempotence : pas supprimé → no-op silencieux.
  IF v_was_deleted IS NULL THEN
    RETURN jsonb_build_object(
      'product_id',  p_product_id,
      'restored_at', NULL,
      'already',     true
    );
  END IF;

  -- ── 4. Restauration. On purge les colonnes soft-delete MAIS on ne
  --       touche PAS à is_active ni is_visible_web : le manager doit
  --       republier manuellement (gestion explicite de la visibilité
  --       après audit). archived_snapshot est conservé pour traçabilité.
  UPDATE public.products
     SET deleted_at    = NULL,
         deleted_by    = NULL,
         delete_reason = NULL
   WHERE id = p_product_id;

  -- ── 5. Trace activity_logs.
  INSERT INTO public.activity_logs (
    actor_id, actor_email,
    action, target_type, target_id, target_label,
    shop_id, details, created_at
  )
  SELECT
    auth.uid(),
    (SELECT email FROM auth.users WHERE id = auth.uid()),
    'product_restored',
    'product',
    p_product_id,
    v_name,
    v_store_id::uuid,
    jsonb_build_object(
      'restored_by',    p_user_id,
      'was_deleted_at', v_was_deleted
    ),
    NOW();

  RETURN jsonb_build_object(
    'product_id',  p_product_id,
    'restored_at', NOW(),
    'already',     false
  );
END;
$fn$;

ALTER FUNCTION public.restore_product(text, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.restore_product(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.restore_product(text, uuid)
  TO authenticated;

-- ────────────────────────────────────────────────────────────────────────
-- Test manuel
-- ───────────
--   1) INSERT produit sans stock, sans variant, sans ventes ouvertes.
--      → SELECT delete_product('prod_xxx', auth.uid(), 'Référence remplacée');
--         → RETURN {product_id, deleted_at, already:false}. La ligne reste
--         dans products mais invisible aux membres (RLS).
--   2) Re-appel delete_product(... même id ...) → {..., already:true}.
--   3) INSERT stock_levels.stock_available=5 pour une variant_id du produit ;
--      delete_product → ERROR produit_en_stock (P0001), DETAIL.stock_total=5.
--   4) Évacuer le stock, créer commande status='scheduled' référençant le
--      product ; delete_product → ERROR produit_commandes_ouvertes (P0001),
--      DETAIL.open_orders_count=1.
--   5) delete_product(... motif='court') → ERROR motif_required (P0001).
--   6) En tant qu'employé (role='user') → ERROR permission_insuffisante (42501).
--   7) SELECT id FROM products WHERE id='prod_xxx' (membre) → 0 lignes.
--      Idem (super-admin) → 1 ligne.
--   8) restore_product en tant que membre → ERROR permission_insuffisante.
--   9) Idem en tant que super-admin → produit visible à nouveau, MAIS
--      is_active=false et is_visible_web=false (manager doit republier).
--  10) DELETE direct depuis SQL Editor sur le produit → trigger hotfix_083
--      bloque toujours (filet de sécurité). La RPC reste le seul chemin.
-- ────────────────────────────────────────────────────────────────────────
-- Fin — hotfix_085_products_soft_delete.sql
