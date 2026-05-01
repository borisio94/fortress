-- =============================================================================
-- 012 — Enrichit danger_action_logs avec un snapshot de l'email de l'acteur
--
-- Pourquoi un snapshot et pas un join sur profiles/auth.users ?
--   - Les logs doivent rester lisibles APRÈS suppression du compte
--     (audit trail). Un join orphelin afficherait NULL.
--   - Évite un round-trip supplémentaire à l'affichage de la page Historique
--     sécurité.
--
-- Idempotente.
-- =============================================================================

ALTER TABLE public.danger_action_logs
  ADD COLUMN IF NOT EXISTS user_email TEXT;

-- Backfill best-effort des lignes existantes depuis auth.users.
UPDATE public.danger_action_logs l
   SET user_email = u.email
  FROM auth.users u
 WHERE l.user_id IS NOT NULL
   AND l.user_email IS NULL
   AND u.id = l.user_id;
