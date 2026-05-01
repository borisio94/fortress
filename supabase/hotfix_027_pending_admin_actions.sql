-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_027_pending_admin_actions.sql
--
-- Workflow d'approbation owner pour les actions sensibles déclenchées par
-- un admin (ÉTAPE 8 spec hotfix_024) :
--
--   1. Admin demande → INSERT pending_admin_actions (status='pending')
--   2. Owner online (last_seen_at < 90s) → reçoit notif via Realtime
--   3. Owner re-saisit son mot de passe (vérifié client-side via
--      signInWithPassword) puis appelle approve_admin_action
--   4. RPC exécute l'action puis passe la ligne en status='approved'
--
-- Si owner offline → l'admin reçoit l'erreur 'OWNER_OFFLINE' et la
-- demande n'est pas créée.
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1. Présence online : profiles.last_seen_at ──────────────────────────
ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS last_seen_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_profiles_last_seen
  ON profiles(last_seen_at);

-- RPC appelée par l'app toutes les 90s pour mettre à jour la présence
CREATE OR REPLACE FUNCTION public.update_my_last_seen()
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $heartbeat$
BEGIN
  IF auth.uid() IS NULL THEN RETURN; END IF;
  UPDATE profiles SET last_seen_at = now()
   WHERE id = auth.uid();
END;
$heartbeat$;

GRANT EXECUTE ON FUNCTION public.update_my_last_seen() TO authenticated;

-- RPC : vérifie si le propriétaire d'une boutique est online (< 90s)
CREATE OR REPLACE FUNCTION public.is_owner_online(p_shop_id TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $is_online$
DECLARE
  v_last TIMESTAMPTZ;
BEGIN
  SELECT pr.last_seen_at INTO v_last
    FROM shops s
    JOIN profiles pr ON pr.id::text = s.owner_id::text
   WHERE s.id::text = p_shop_id;
  RETURN v_last IS NOT NULL
     AND v_last > now() - INTERVAL '90 seconds';
END;
$is_online$;

GRANT EXECUTE ON FUNCTION public.is_owner_online(TEXT) TO authenticated;

-- ── 2. Table pending_admin_actions ───────────────────────────────────────
CREATE TABLE IF NOT EXISTS pending_admin_actions (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id         TEXT NOT NULL,
  requester_id    UUID NOT NULL,
  target_user_id  UUID,            -- null pour delete_shop
  action_type     TEXT NOT NULL
    CHECK (action_type IN ('remove_admin','demote_admin','delete_shop')),
  status          TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','approved','rejected','expired')),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at      TIMESTAMPTZ NOT NULL DEFAULT (now() + INTERVAL '5 minutes'),
  approved_by     UUID,
  approved_at     TIMESTAMPTZ,
  rejection_reason TEXT
);

CREATE INDEX IF NOT EXISTS idx_pending_admin_shop_status
  ON pending_admin_actions(shop_id, status);

ALTER TABLE pending_admin_actions ENABLE ROW LEVEL SECURITY;

-- RLS : un user voit ses propres requêtes (en tant que requester ou en
-- tant que target). Le owner voit tout pour ses shops.
DROP POLICY IF EXISTS pending_actions_select ON pending_admin_actions;
CREATE POLICY pending_actions_select ON pending_admin_actions FOR SELECT
  USING (
    requester_id::text = auth.uid()::text
    OR target_user_id::text = auth.uid()::text
    OR EXISTS (SELECT 1 FROM shops
                WHERE id::text = shop_id
                  AND owner_id::text = auth.uid()::text)
  );

-- INSERT/UPDATE bloqué directement : passe par les RPCs SECURITY DEFINER
DROP POLICY IF EXISTS pending_actions_no_direct_write ON pending_admin_actions;
CREATE POLICY pending_actions_no_direct_write ON pending_admin_actions
  FOR ALL USING (false) WITH CHECK (false);

-- ── 3. RPC : admin demande une action ────────────────────────────────────
CREATE OR REPLACE FUNCTION public.request_admin_action(
  p_shop_id        TEXT,
  p_target_user_id UUID,
  p_action_type    TEXT
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $req$
DECLARE
  v_action_id UUID;
  v_uid       UUID := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'NOT_AUTHENTICATED' USING ERRCODE = '42501';
  END IF;

  IF p_action_type NOT IN ('remove_admin','demote_admin','delete_shop') THEN
    RAISE EXCEPTION 'INVALID_ACTION_TYPE' USING ERRCODE = '22023';
  END IF;

  -- Le demandeur doit être admin (ou owner mais le owner exécute en direct
  -- sans passer par cette RPC). On bloque user normal et non-membre.
  IF NOT EXISTS (
    SELECT 1 FROM shop_memberships
     WHERE shop_id::text = p_shop_id
       AND user_id::text = v_uid::text
       AND role = 'admin'
       AND COALESCE(status, 'active') = 'active'
  ) THEN
    RAISE EXCEPTION 'NOT_ADMIN' USING ERRCODE = '42501';
  END IF;

  -- Vérifier que le owner est online
  IF NOT public.is_owner_online(p_shop_id) THEN
    RAISE EXCEPTION 'OWNER_OFFLINE' USING ERRCODE = '57000';
  END IF;

  -- Garde-fou : pas de doublon en attente sur la même target/action
  IF EXISTS (
    SELECT 1 FROM pending_admin_actions
     WHERE shop_id        = p_shop_id
       AND target_user_id IS NOT DISTINCT FROM p_target_user_id
       AND action_type    = p_action_type
       AND status         = 'pending'
       AND expires_at     > now()
  ) THEN
    RAISE EXCEPTION 'DUPLICATE_PENDING' USING ERRCODE = '23505';
  END IF;

  INSERT INTO pending_admin_actions
      (shop_id, requester_id, target_user_id, action_type)
  VALUES
      (p_shop_id, v_uid, p_target_user_id, p_action_type)
  RETURNING id INTO v_action_id;

  RETURN v_action_id;
END;
$req$;

GRANT EXECUTE ON FUNCTION public.request_admin_action(TEXT, UUID, TEXT)
  TO authenticated;

-- ── 4. RPC : owner approuve l'action ─────────────────────────────────────
-- Le mot de passe a été re-vérifié côté client via signInWithPassword.
-- Côté serveur on fait confiance à auth.uid() qui doit être le owner.
CREATE OR REPLACE FUNCTION public.approve_admin_action(p_action_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $approve$
DECLARE
  v_action  pending_admin_actions%ROWTYPE;
  v_uid_t   TEXT := auth.uid()::text;
  v_owner_t TEXT;
BEGIN
  SELECT * INTO v_action FROM pending_admin_actions
   WHERE id = p_action_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ACTION_NOT_FOUND' USING ERRCODE = '02000';
  END IF;
  IF v_action.status <> 'pending' THEN
    RAISE EXCEPTION 'ACTION_ALREADY_PROCESSED' USING ERRCODE = '22023';
  END IF;
  IF v_action.expires_at <= now() THEN
    UPDATE pending_admin_actions SET status = 'expired' WHERE id = p_action_id;
    RAISE EXCEPTION 'ACTION_EXPIRED' USING ERRCODE = '22023';
  END IF;

  -- Vérifier que l'appelant est bien le owner du shop (cast ::text car
  -- shops.owner_id peut être TEXT dans les schémas legacy).
  SELECT owner_id::text INTO v_owner_t FROM shops
   WHERE id::text = v_action.shop_id;
  IF v_owner_t IS DISTINCT FROM v_uid_t THEN
    RAISE EXCEPTION 'NOT_OWNER' USING ERRCODE = '42501';
  END IF;

  -- Exécuter l'action selon son type
  CASE v_action.action_type
    WHEN 'remove_admin' THEN
      DELETE FROM shop_memberships
       WHERE shop_id::text = v_action.shop_id
         AND user_id::text = v_action.target_user_id::text
         AND role = 'admin';
    WHEN 'demote_admin' THEN
      UPDATE shop_memberships
         SET role = 'user'
       WHERE shop_id::text = v_action.shop_id
         AND user_id::text = v_action.target_user_id::text
         AND role = 'admin';
    WHEN 'delete_shop' THEN
      -- Délègue à delete_user_account pour purger les dépendances ?
      -- Non : ici on supprime juste le shop, pas tout le compte du owner.
      -- On purge via _purge_shop_dependents puis DELETE shops.
      PERFORM public._purge_shop_dependents(ARRAY[v_action.shop_id]);
      DELETE FROM shops WHERE id::text = v_action.shop_id;
  END CASE;

  -- Marquer la requête comme approuvée
  UPDATE pending_admin_actions
     SET status = 'approved',
         approved_by = auth.uid(),
         approved_at = now()
   WHERE id = p_action_id;

  RETURN jsonb_build_object(
    'action',  v_action.action_type,
    'shop_id', v_action.shop_id,
    'target',  v_action.target_user_id,
    'approved_at', now()
  );
END;
$approve$;

ALTER FUNCTION public.approve_admin_action(UUID) OWNER TO postgres;
GRANT EXECUTE ON FUNCTION public.approve_admin_action(UUID) TO authenticated;

-- ── 5. RPC : owner rejette l'action ──────────────────────────────────────
CREATE OR REPLACE FUNCTION public.reject_admin_action(
  p_action_id UUID,
  p_reason    TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $reject$
DECLARE
  v_action  pending_admin_actions%ROWTYPE;
  v_uid_t   TEXT := auth.uid()::text;
  v_owner_t TEXT;
BEGIN
  SELECT * INTO v_action FROM pending_admin_actions
   WHERE id = p_action_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ACTION_NOT_FOUND' USING ERRCODE = '02000';
  END IF;
  IF v_action.status <> 'pending' THEN
    RAISE EXCEPTION 'ACTION_ALREADY_PROCESSED' USING ERRCODE = '22023';
  END IF;

  SELECT owner_id::text INTO v_owner_t FROM shops
   WHERE id::text = v_action.shop_id;
  IF v_owner_t IS DISTINCT FROM v_uid_t THEN
    RAISE EXCEPTION 'NOT_OWNER' USING ERRCODE = '42501';
  END IF;

  UPDATE pending_admin_actions
     SET status = 'rejected',
         rejection_reason = p_reason,
         approved_at = now(),
         approved_by = auth.uid()
   WHERE id = p_action_id;
END;
$reject$;

GRANT EXECUTE ON FUNCTION public.reject_admin_action(UUID, TEXT)
  TO authenticated;

-- ── 6. Cleanup automatique : marquer les actions expirées ────────────────
-- À appeler périodiquement par l'app ou via cron Supabase.
CREATE OR REPLACE FUNCTION public.expire_pending_admin_actions()
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $expire$
DECLARE v_count INT;
BEGIN
  UPDATE pending_admin_actions
     SET status = 'expired'
   WHERE status = 'pending'
     AND expires_at <= now();
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$expire$;

GRANT EXECUTE ON FUNCTION public.expire_pending_admin_actions()
  TO authenticated;
