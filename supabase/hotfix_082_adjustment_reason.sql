-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_082_adjustment_reason.sql
--
-- PR-C des 8 garde-fous stock — GF-7 (motif obligatoire sur ajustements
-- manuels). Ajoute `reason TEXT` sur `stock_movements` + CHECK qui exige
-- une valeur non vide quand `type = 'adjustment'`. Côté Flutter, la même
-- règle est ré-imposée AVANT toute écriture (`StockService.adjustment`
-- lève `AdjustmentReasonRequiredException`), donc la contrainte SQL est
-- un double verrou défensif contre les INSERT directs (sync queue
-- corrompu, debug manuel, intégration tierce).
--
-- Idempotent : ADD COLUMN IF NOT EXISTS + DROP CONSTRAINT IF EXISTS avant
-- l'ADD CONSTRAINT.
--
-- ⚠ GF-6 (réception anormale) ne nécessite PAS de SQL : la détection
-- 3×moyenne et le log d'anomalie sont 100% Flutter (Hive + activity_logs).
-- ════════════════════════════════════════════════════════════════════════════

-- ─── 1. stock_movements.reason ───────────────────────────────────────────
ALTER TABLE IF EXISTS public.stock_movements
  ADD COLUMN IF NOT EXISTS reason TEXT;

-- ─── 2. CHECK : reason obligatoire pour type = 'adjustment' ──────────────
-- DROP avant ADD pour rester idempotent (les ALTER TABLE … ADD CONSTRAINT
-- IF NOT EXISTS n'existent pas avant PG18).
ALTER TABLE IF EXISTS public.stock_movements
  DROP CONSTRAINT IF EXISTS stock_movements_reason_required;

ALTER TABLE IF EXISTS public.stock_movements
  ADD CONSTRAINT stock_movements_reason_required
    CHECK (type <> 'adjustment'
           OR (reason IS NOT NULL AND length(trim(reason)) > 0));

-- ────────────────────────────────────────────────────────────────────────
-- Test manuel :
--   1) Tenter INSERT INTO stock_movements (..., type='adjustment',
--      reason=NULL) → ERROR violates check constraint
--      'stock_movements_reason_required'.
--   2) INSERT type='adjustment', reason='Correction inventaire' → OK.
--   3) INSERT type='sale', reason=NULL → OK (la contrainte ne s'applique
--      qu'à 'adjustment').
-- ────────────────────────────────────────────────────────────────────────
