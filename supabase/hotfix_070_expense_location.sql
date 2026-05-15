-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_070_expense_location.sql
--
-- Permet de rattacher une dépense à un emplacement précis (boutique de base
-- ou partenaire) ou de la laisser globale.
--
-- Convention de `location_id` (cohérente avec dashViewFilterProvider) :
--   • NULL     → dépense GLOBALE (charge non attribuable : loyer général,
--                abonnement logiciel…). Comptée partout.
--   • '_base'  → dépense de la BOUTIQUE (StockLocation type='shop').
--   • <uuid>   → dépense d'un PARTENAIRE précis (StockLocation type='partner').
--
-- Idempotent.
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

ALTER TABLE public.expenses
  ADD COLUMN IF NOT EXISTS location_id text;

CREATE INDEX IF NOT EXISTS expenses_location_idx
  ON public.expenses (shop_id, location_id);

COMMIT;
