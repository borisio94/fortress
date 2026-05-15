-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_069_promo_starts_at.sql
--
-- Ajoute une date de début planifiée aux campagnes promo. L'app exige un
-- délai minimum entre `now()` et `starts_at` pour éviter qu'une campagne
-- soit activée par erreur sans réflexion.
--
-- Idempotent.
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

ALTER TABLE public.promo_campaigns
  ADD COLUMN IF NOT EXISTS starts_at timestamptz;

-- Backfill : les campagnes existantes démarrent à leur created_at (donc
-- déjà actives).
UPDATE public.promo_campaigns
   SET starts_at = created_at
 WHERE starts_at IS NULL;

COMMIT;
