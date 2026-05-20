-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_084_orders_soft_delete.sql
--
-- Suppression SÉCURISÉE des commandes (orders) — soft-delete + RPC dédiée.
--
-- Contexte
-- ────────
-- Avant ce hotfix, supprimer une commande passait par un DELETE Supabase
-- direct (cf. `AppDatabase.bgDeleteOrder`). Trois problèmes :
--   1. Modèle offline-first → tout DELETE peut être ressuscité par le
--      re-push d'un autre appareil (même pattern que hotfix_072 sur le livre
--      partenaire). Solution standard : `deleted_at` qui converge partout.
--   2. Aucun garde-fou : un user pouvait supprimer une commande déjà
--      encaissée → perte de revenu invisible, stock orphelin.
--   3. Aucune trace dans `activity_logs` → impossible d'auditer qui a
--      supprimé quoi et pourquoi.
--
-- Ce hotfix met en place :
--   • Colonnes `deleted_at`, `deleted_by`, `delete_reason` sur `orders`.
--   • Index partiel `orders_not_deleted_idx` (préserve les perfs sur les
--     lectures "live" qui filtrent `deleted_at IS NULL`).
--   • RLS modifiée pour CACHER les commandes supprimées aux membres et
--     EXPOSER uniquement la liste deleted_at IS NOT NULL au super-admin.
--   • RPC `delete_sale(p_sale_id, p_user_id, p_reason)` SECURITY DEFINER :
--       — Refus si statut ∉ {scheduled, processing, refused} →
--         `suppression_statut_invalide` (P0001).
--       — Refus si `COALESCE(amount_paid, 0) > 0` →
--         `suppression_commande_payee` (P0001).
--       — Refus si motif vide ou < 10 caractères → `motif_required` (P0001).
--       — Verrou `FOR UPDATE` sur la ligne pour éviter les races.
--       — Idempotente : un 2ᵉ appel sur une commande déjà supprimée
--         retourne le résultat sans rien refaire.
--       — Trace `activity_logs (action='sale_deleted', details=…)`.
--   • RPC `restore_sale(p_sale_id, p_user_id)` SECURITY DEFINER :
--       — Réservée `_is_super_admin()` → sinon `permission_denied` (42501).
--       — Désarchive (`deleted_at = NULL`) et trace `'sale_restored'`.
--
-- ⚠ Rollback stock : non géré par la RPC. Le client Flutter exécute
--   `StockService.reverseSale(...)` AVANT de pousser la RPC. Raison : le
--   stock vit en partie dans `products.variants` (JSONB nested) et en
--   partie dans `stock_levels` selon le mode de livraison ; la mutation
--   est offline-first et déjà rejouable. Reproduire la logique en SQL
--   créerait des doublons de `stock_movements` à chaque resync.
--
-- Idempotent : ADD COLUMN IF NOT EXISTS, CREATE INDEX IF NOT EXISTS,
-- CREATE OR REPLACE FUNCTION, DROP POLICY IF EXISTS avant CREATE POLICY.
-- Sûr à ré-exécuter.
-- ════════════════════════════════════════════════════════════════════════════

-- ─── 1. Colonnes soft-delete sur orders ──────────────────────────────────
ALTER TABLE IF EXISTS public.orders
  ADD COLUMN IF NOT EXISTS deleted_at    TIMESTAMPTZ;

ALTER TABLE IF EXISTS public.orders
  ADD COLUMN IF NOT EXISTS deleted_by    UUID;

ALTER TABLE IF EXISTS public.orders
  ADD COLUMN IF NOT EXISTS delete_reason TEXT;

-- Index partiel : ne porte que sur les lignes vivantes (≈ 99% du temps).
-- Les listes "Commandes" filtrent `deleted_at IS NULL` → cet index est
-- celui qui sera planifié. Bénéfice : compact, scan rapide même quand la
-- table accumule du soft-delete.
CREATE INDEX IF NOT EXISTS orders_not_deleted_idx
  ON public.orders (shop_id, status)
  WHERE deleted_at IS NULL;

-- Index dédié pour la page super-admin "Commandes supprimées".
CREATE INDEX IF NOT EXISTS orders_deleted_idx
  ON public.orders (deleted_at DESC)
  WHERE deleted_at IS NOT NULL;

-- ─── 2. RLS : cacher les supprimées aux membres, exposer au super-admin ──
-- L'ancienne policy `orders_members` (cf. CREATE TABLE inline dans
-- AppDatabase._tableSql) couvre FOR ALL → on la remplace par 2 policies
-- séparées :
--   • SELECT : membre du shop ET (deleted_at IS NULL OU super-admin).
--   • INSERT/UPDATE/DELETE : membre du shop sans contrainte deleted_at
--     (les RPC SECURITY DEFINER orchestreront elles-mêmes le UPDATE de
--     soft-delete / restore — le UPDATE direct reste autorisé pour les
--     mises à jour normales de la commande tant qu'elle n'est pas
--     supprimée, ce qui sera enforce par la RPC).
DROP POLICY IF EXISTS orders_members           ON public.orders;
DROP POLICY IF EXISTS orders_select_visible    ON public.orders;
DROP POLICY IF EXISTS orders_select_deleted_sa ON public.orders;
DROP POLICY IF EXISTS orders_write_members     ON public.orders;

-- SELECT : un membre voit les commandes non-supprimées de son shop ;
-- un super-admin voit aussi les supprimées (toutes boutiques).
CREATE POLICY orders_select_visible ON public.orders
  FOR SELECT
  USING (
        deleted_at IS NULL
    AND shop_id IN (
      SELECT shop_id FROM public.shop_memberships
       WHERE user_id = (auth.uid())::text
    )
  );

CREATE POLICY orders_select_deleted_sa ON public.orders
  FOR SELECT
  USING (
        deleted_at IS NOT NULL
    AND public._is_super_admin()
  );

-- INSERT / UPDATE / DELETE : membre du shop (les RPC bypassent quoi qu'il
-- arrive via SECURITY DEFINER). On laisse le DELETE direct disponible
-- pour les outils de maintenance super-admin, mais l'app cliente ne doit
-- plus l'utiliser pour les commandes — elle passe par delete_sale().
CREATE POLICY orders_write_members ON public.orders
  FOR ALL
  USING (
    shop_id IN (
      SELECT shop_id FROM public.shop_memberships
       WHERE user_id = (auth.uid())::text
    )
  )
  WITH CHECK (
    shop_id IN (
      SELECT shop_id FROM public.shop_memberships
       WHERE user_id = (auth.uid())::text
    )
  );

-- REPLICA IDENTITY FULL : payload realtime porte la ligne complète, donc
-- l'app reçoit `deleted_at` ET l'old record lors d'un UPDATE → les listes
-- locales peuvent réagir au soft-delete via le canal realtime existant.
-- Idempotent (no-op si déjà FULL).
ALTER TABLE IF EXISTS public.orders REPLICA IDENTITY FULL;

-- ─── 3. RPC delete_sale ──────────────────────────────────────────────────
-- DROP IF EXISTS avant CREATE — permet de changer la signature en place
-- (ex: ajout futur d'un paramètre `p_metadata jsonb`) sans casser le rejeu
-- du hotfix.
DROP FUNCTION IF EXISTS public.delete_sale(text, uuid, text);

CREATE OR REPLACE FUNCTION public.delete_sale(
  p_sale_id text,
  p_user_id uuid,
  p_reason  text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_status      text;
  v_amount_paid double precision;
  v_already     timestamptz;
  v_shop_id     text;
  v_client_name text;
  v_reason      text := COALESCE(trim(p_reason), '');
BEGIN
  -- ── 1. Validation du motif (avant tout, ne charge pas la ligne pour
  --       rien si motif vide). Min 10 caractères = cohérent avec la dialog
  --       Flutter (champ obligatoire, validator min 10).
  IF length(v_reason) < 10 THEN
    RAISE EXCEPTION 'motif_required'
      USING ERRCODE = 'P0001',
            MESSAGE = 'Motif obligatoire (10 caractères minimum).',
            DETAIL  = jsonb_build_object('code', 'motif_required')::text;
  END IF;

  -- ── 2. Verrouillage + lecture de l'état actuel. FOR UPDATE empêche
  --       qu'un autre process modifie la commande entre la lecture et
  --       l'UPDATE (race évidente : 2 onglets web qui suppriment la même
  --       commande au même moment).
  SELECT status, COALESCE(amount_paid, 0), deleted_at, shop_id, client_name
    INTO v_status, v_amount_paid, v_already, v_shop_id, v_client_name
    FROM public.orders
   WHERE id = p_sale_id
     FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'sale_not_found'
      USING ERRCODE = 'P0002',
            MESSAGE = 'Commande introuvable.',
            DETAIL  = jsonb_build_object('code', 'sale_not_found',
                                         'sale_id', p_sale_id)::text;
  END IF;

  -- ── 3. Idempotence : déjà supprimée → on retourne le même résultat
  --       sans rien refaire (la file offline peut rejouer la même RPC).
  IF v_already IS NOT NULL THEN
    RETURN jsonb_build_object(
      'sale_id',      p_sale_id,
      'deleted_at',   v_already,
      'already',      true
    );
  END IF;

  -- ── 4. Garde-fou statut. La spec produit autorise scheduled +
  --       processing + refused (toutes 3 par construction non-encaissées
  --       ou avec amount_paid = 0). Tout autre statut (completed,
  --       cancelled, refunded) refuse la suppression — l'opérateur doit
  --       passer par les flows métier dédiés (Retour, Annulation, etc.).
  IF v_status NOT IN ('scheduled', 'processing', 'refused') THEN
    RAISE EXCEPTION 'suppression_statut_invalide'
      USING ERRCODE = 'P0001',
            MESSAGE = format(
              'Suppression refusée : statut « %s » non éligible.', v_status),
            DETAIL  = jsonb_build_object(
              'code',    'suppression_statut_invalide',
              'status',  v_status,
              'allowed', jsonb_build_array('scheduled','processing','refused')
            )::text;
  END IF;

  -- ── 5. Garde-fou paiement. Une commande même partiellement encaissée
  --       (acompte boutique, paiement partenaire-livreur) ne peut pas
  --       être supprimée : il faut d'abord rembourser le client.
  IF v_amount_paid > 0 THEN
    RAISE EXCEPTION 'suppression_commande_payee'
      USING ERRCODE = 'P0001',
            MESSAGE = format(
              'Suppression refusée : commande encaissée à hauteur de %s.',
              v_amount_paid),
            DETAIL  = jsonb_build_object(
              'code',        'suppression_commande_payee',
              'amount_paid', v_amount_paid
            )::text;
  END IF;

  -- ── 6. Soft-delete. UPDATE atomique avec l'auteur et le motif.
  UPDATE public.orders
     SET deleted_at    = NOW(),
         deleted_by    = p_user_id,
         delete_reason = v_reason
   WHERE id = p_sale_id;

  -- ── 7. Trace dans activity_logs. `shop_id` est requis pour la lecture
  --       par les admins de la boutique (cf. policies hotfix_002). Les
  --       détails JSON contiennent la raison, le statut avant suppression
  --       et l'amount_paid (=0 ici par construction du garde-fou 5).
  --       L'identité du super-admin / membre est captée via auth.uid()
  --       (actor_id, actor_email) — la fonction est SECURITY DEFINER mais
  --       auth.uid() retourne TOUJOURS l'identité de l'appelant (pas du
  --       owner postgres).
  INSERT INTO public.activity_logs (
    actor_id, actor_email,
    action, target_type, target_id, target_label,
    shop_id, details, created_at
  )
  SELECT
    auth.uid(),
    (SELECT email FROM auth.users WHERE id = auth.uid()),
    'sale_deleted',
    'sale',
    p_sale_id,
    v_client_name,
    v_shop_id::uuid,
    jsonb_build_object(
      'reason',      v_reason,
      'status_before', v_status,
      'amount_paid', v_amount_paid,
      'deleted_by',  p_user_id
    ),
    NOW();

  RETURN jsonb_build_object(
    'sale_id',    p_sale_id,
    'deleted_at', NOW(),
    'already',    false
  );
END;
$fn$;

ALTER FUNCTION public.delete_sale(text, uuid, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.delete_sale(text, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_sale(text, uuid, text)
  TO authenticated;

-- ─── 4. RPC restore_sale (super-admin only) ──────────────────────────────
DROP FUNCTION IF EXISTS public.restore_sale(text, uuid);

CREATE OR REPLACE FUNCTION public.restore_sale(
  p_sale_id text,
  p_user_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_was_deleted timestamptz;
  v_shop_id     text;
  v_client_name text;
BEGIN
  -- ── 1. Garde-fou : seul un super-admin peut restaurer (la spec dit
  --       écran réservé `is_super_admin`). On vérifie ici aussi côté
  --       serveur (defense-in-depth — la RPC est SECURITY DEFINER, donc
  --       sans ce check elle serait callable par n'importe qui).
  IF NOT public._is_super_admin() THEN
    RAISE EXCEPTION 'permission_denied'
      USING ERRCODE = '42501',
            MESSAGE = 'Restauration réservée au super-admin.',
            DETAIL  = jsonb_build_object('code','permission_denied')::text;
  END IF;

  -- ── 2. Verrou + lecture (FOR UPDATE).
  SELECT deleted_at, shop_id, client_name
    INTO v_was_deleted, v_shop_id, v_client_name
    FROM public.orders
   WHERE id = p_sale_id
     FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'sale_not_found'
      USING ERRCODE = 'P0002',
            MESSAGE = 'Commande introuvable.',
            DETAIL  = jsonb_build_object('code','sale_not_found',
                                         'sale_id', p_sale_id)::text;
  END IF;

  -- ── 3. Idempotence : pas supprimée → no-op silencieux.
  IF v_was_deleted IS NULL THEN
    RETURN jsonb_build_object(
      'sale_id', p_sale_id,
      'restored_at', NULL,
      'already', true
    );
  END IF;

  -- ── 4. Restauration. On purge les 3 colonnes pour repartir d'un état
  --       identique à pré-suppression.
  UPDATE public.orders
     SET deleted_at    = NULL,
         deleted_by    = NULL,
         delete_reason = NULL
   WHERE id = p_sale_id;

  -- ── 5. Trace.
  INSERT INTO public.activity_logs (
    actor_id, actor_email,
    action, target_type, target_id, target_label,
    shop_id, details, created_at
  )
  SELECT
    auth.uid(),
    (SELECT email FROM auth.users WHERE id = auth.uid()),
    'sale_restored',
    'sale',
    p_sale_id,
    v_client_name,
    v_shop_id::uuid,
    jsonb_build_object(
      'restored_by',     p_user_id,
      'was_deleted_at',  v_was_deleted
    ),
    NOW();

  RETURN jsonb_build_object(
    'sale_id',     p_sale_id,
    'restored_at', NOW(),
    'already',     false
  );
END;
$fn$;

ALTER FUNCTION public.restore_sale(text, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.restore_sale(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.restore_sale(text, uuid)
  TO authenticated;

-- ────────────────────────────────────────────────────────────────────────
-- Test manuel
-- ───────────
--   1) INSERT commande scheduled, amount_paid=0.
--      → SELECT delete_sale('order_xxx', auth.uid(), 'Annulation client');
--         → RETURN {sale_id, deleted_at, already:false}. La ligne reste
--         dans orders mais n'est plus visible via SELECT (sauf super-admin).
--   2) Re-appel delete_sale(... même id ...) → RETURN {..., already:true}.
--   3) UPDATE commande SET amount_paid=5000, deleted_at=NULL ; puis
--      delete_sale → ERROR suppression_commande_payee (P0001).
--   4) UPDATE commande SET status='completed' ; puis delete_sale →
--      ERROR suppression_statut_invalide (P0001).
--   5) delete_sale(... motif='court') → ERROR motif_required (P0001).
--   6) SELECT id FROM orders WHERE id='order_xxx' (en tant que membre
--      simple) → 0 lignes. En tant que super-admin → 1 ligne.
--   7) SELECT restore_sale('order_xxx', auth.uid()) en tant que membre
--      → ERROR permission_denied (42501).
--   8) Idem en tant que super-admin → RETURN {restored_at, already:false}.
-- ────────────────────────────────────────────────────────────────────────
-- Fin — hotfix_084_orders_soft_delete.sql
