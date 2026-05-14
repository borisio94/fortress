-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_063_pricing_canvas_v2.sql
--
-- Alignement de la grille tarifaire publique sur le canvas commercial v2 :
--   Trial    14 jours (au lieu de 7) — masqué du /pricing public.
--   Starter   3 500 FCFA/mois  ·  31 500 FCFA/an (-25 %)
--             1 boutique · 1 dépôt partenaire · 1 employé.
--   Pro       8 500 FCFA/mois  ·  76 500 FCFA/an
--             1 boutique · 3 dépôts partenaires · 3 employés + features.
--   Business 18 000 FCFA/mois  · 162 000 FCFA/an
--             3 boutiques · 3 dépôts partenaires · 3 employés + intégrations.
--
-- IMPORTANT — le plan 'trial' reste en base avec `is_active=false` car le
-- trigger SQL `create_trial_subscription()` (cf. hotfix_020) le lit pour
-- générer les essais auto à chaque self-signup (`WHERE name='trial'`). Le
-- supprimer casserait les nouveaux signups. L'app exclut côté Flutter les
-- plans `is_active=false` du /pricing public.
--
-- Idempotent : conçu pour s'appliquer même si les colonnes ajoutées
-- existent déjà partiellement (ALTER TABLE ... IF NOT EXISTS).
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── Nouvelles colonnes pour la sémantique canvas (idempotent) ──────────────
-- `max_users_per_shop` existant ≠ employés (= membres total). On ajoute des
-- colonnes dédiées pour aligner sur le wording marketing du canvas.
ALTER TABLE plans
  ADD COLUMN IF NOT EXISTS max_partner_depots_per_shop INT DEFAULT 0;
ALTER TABLE plans
  ADD COLUMN IF NOT EXISTS max_employees_per_shop      INT DEFAULT 0;

-- ── Trial : 7 → 14 jours, masqué du /pricing public ──────────────────────
UPDATE plans SET
  trial_days = 14,
  is_active  = false
WHERE name = 'trial';

-- ── Starter : 5000→3500 monthly · 50000→31500 yearly (-25 %) ─────────────
UPDATE plans SET
  price_monthly               = 3500,
  price_yearly                = 31500,
  max_partner_depots_per_shop = 1,
  max_employees_per_shop      = 1,
  is_active                   = true,
  sort_order                  = 1
WHERE name = 'starter';

-- ── Pro : 10000→8500 monthly · 100000→76500 yearly ────────────────────────
UPDATE plans SET
  price_monthly               = 8500,
  price_yearly                = 76500,
  max_partner_depots_per_shop = 3,
  max_employees_per_shop      = 3,
  is_active                   = true,
  sort_order                  = 2
WHERE name = 'pro';

-- ── Business : 25000→18000 monthly · 250000→162000 yearly · 3 boutiques ──
UPDATE plans SET
  price_monthly               = 18000,
  price_yearly                = 162000,
  max_shops                   = 3,
  max_partner_depots_per_shop = 3,
  max_employees_per_shop      = 3,
  is_active                   = true,
  sort_order                  = 3
WHERE name = 'business';

COMMIT;

-- ── Vérification post-migration (à exécuter manuellement après COMMIT) ───
-- SELECT name, price_monthly, price_yearly, trial_days, is_active,
--        max_shops, max_partner_depots_per_shop, max_employees_per_shop,
--        sort_order
--   FROM plans ORDER BY sort_order;
