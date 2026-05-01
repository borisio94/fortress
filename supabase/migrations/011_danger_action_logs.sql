-- =============================================================================
-- 011 — Table d'audit des actions destructives (danger_action_logs)
--
-- Trace TOUTES les tentatives d'actions destructives orchestrées par
-- DangerActionService côté Flutter (succès ET échecs) pour audit, support
-- et détection d'abus.
--
-- Schéma volontairement plat — pas de FK vers shops/auth.users côté serveur :
-- les logs doivent SURVIVRE à la suppression de la cible (la trace de
-- "Boutique X a été supprimée par user Y" reste lisible même quand Boutique X
-- a disparu).
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.danger_action_logs (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id       TEXT,                   -- NULL si l'action ne porte pas sur une boutique
  user_id       UUID,                   -- acteur (peut devenir NULL si compte supprimé)
  action        TEXT        NOT NULL,   -- clé enum : delete_shop, delete_admin, …
  target_id     TEXT,                   -- id de la cible (shop, user, product, …)
  target_label  TEXT,                   -- libellé humain de la cible (snapshot)
  executed_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  success       BOOLEAN     NOT NULL,
  error_message TEXT                    -- raison d'échec (cancelled, pin_locked, exception, …)
);

CREATE INDEX IF NOT EXISTS idx_danger_action_logs_shop_id
  ON public.danger_action_logs (shop_id);
CREATE INDEX IF NOT EXISTS idx_danger_action_logs_user_id
  ON public.danger_action_logs (user_id);
CREATE INDEX IF NOT EXISTS idx_danger_action_logs_executed_at
  ON public.danger_action_logs (executed_at DESC);

-- ─── RLS ───────────────────────────────────────────────────────────────────
ALTER TABLE public.danger_action_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS danger_action_logs_insert_authenticated ON public.danger_action_logs;
DROP POLICY IF EXISTS danger_action_logs_select_owner_or_sa   ON public.danger_action_logs;

-- INSERT : tout user authentifié peut journaliser SES propres tentatives.
--   - user_id doit être l'appelant (sécurité contre l'usurpation de logs).
--   - shop_id (si fourni) doit être une boutique dont l'appelant est membre.
CREATE POLICY danger_action_logs_insert_authenticated
  ON public.danger_action_logs
  FOR INSERT
  TO authenticated
  WITH CHECK (
    (user_id)::text = (auth.uid())::text
    AND (
      shop_id IS NULL
      OR (shop_id)::text IN (SELECT public.user_shop_ids())
      OR (shop_id)::text IN (SELECT public.user_owned_shop_ids())
    )
  );

-- SELECT : owner de la boutique concernée, OU super_admin.
--   Les logs orphelins (shop_id NULL) ne sont visibles que par super_admin.
CREATE POLICY danger_action_logs_select_owner_or_sa
  ON public.danger_action_logs
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE (p.id)::text = (auth.uid())::text
        AND COALESCE(p.is_super_admin, false) = true
    )
    OR (
      shop_id IS NOT NULL
      AND (shop_id)::text IN (SELECT public.user_owned_shop_ids())
    )
  );

-- UPDATE / DELETE : interdit aux clients (logs immuables côté app).
-- Les opérations de purge admin passent par une RPC SECURITY DEFINER dédiée.
