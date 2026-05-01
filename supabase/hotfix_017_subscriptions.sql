-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_017_subscriptions.sql
-- Système d'abonnement Fortress :
--   - 4 plans : trial · starter · pro · business
--   - Abonnement par utilisateur (user_id), un seul actif/trial à la fois
--   - Trial 7 jours auto à la création d'un profil
--   - Activation manuelle par super_admin (Mobile Money / WhatsApp)
--
-- Idempotent : conçu pour s'appliquer même si les tables `plans` et
-- `subscriptions` existent déjà partiellement (migration douce).
--
-- ⚠ Important : les blocs PL/pgSQL utilisent des tags nommés ($fk$, $chk$,
-- $set_annual$, $get_plan$, $create_trial$, $expire$) plutôt que `$$`.
-- Les `$$` génériques sont mal parsés par certains éditeurs SQL quand
-- plusieurs fonctions sont définies dans le même script.
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1. Table plans ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS plans (
  id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT UNIQUE NOT NULL
);

-- Colonnes ajoutées progressivement (idempotent)
ALTER TABLE plans ADD COLUMN IF NOT EXISTS label              TEXT;
ALTER TABLE plans ADD COLUMN IF NOT EXISTS price_monthly      NUMERIC(12,2) DEFAULT 0;
ALTER TABLE plans ADD COLUMN IF NOT EXISTS price_quarterly    NUMERIC(12,2) DEFAULT 0;
ALTER TABLE plans ADD COLUMN IF NOT EXISTS price_yearly       NUMERIC(12,2) DEFAULT 0;
ALTER TABLE plans ADD COLUMN IF NOT EXISTS max_shops          INT  DEFAULT 1;
ALTER TABLE plans ADD COLUMN IF NOT EXISTS max_users_per_shop INT  DEFAULT 1;
ALTER TABLE plans ADD COLUMN IF NOT EXISTS max_products       INT  DEFAULT 50;
ALTER TABLE plans ADD COLUMN IF NOT EXISTS offline_enabled    BOOLEAN DEFAULT false;
ALTER TABLE plans ADD COLUMN IF NOT EXISTS features           JSONB   DEFAULT '[]'::jsonb;
ALTER TABLE plans ADD COLUMN IF NOT EXISTS trial_days         INT     DEFAULT 0;
ALTER TABLE plans ADD COLUMN IF NOT EXISTS is_active          BOOLEAN DEFAULT true;
ALTER TABLE plans ADD COLUMN IF NOT EXISTS sort_order         INT     DEFAULT 0;
ALTER TABLE plans ADD COLUMN IF NOT EXISTS created_at         TIMESTAMPTZ DEFAULT now();

-- Migration douce : ancien plan 'normal' → 'starter'
UPDATE plans SET name='starter', label='Starter' WHERE name='normal';

-- Seed des 4 plans (idempotent — UPSERT par name)
INSERT INTO plans (name, label, price_monthly, price_quarterly, price_yearly,
                   max_shops, max_users_per_shop, max_products,
                   offline_enabled, features, trial_days, sort_order)
VALUES
  ('trial',    'Essai',    0,     0,      0,
   1, 2, 50,   false, '[]'::jsonb, 7, 0),
  ('starter',  'Starter',  5000,  13500,  50000,
   1, 2, 500,  false, '[]'::jsonb, 0, 1),
  ('pro',      'Pro',      10000, 27000,  100000,
   3, 10, 2147483647, true,
   '["multiShop","advancedReports","csvExport","finances"]'::jsonb, 0, 2),
  ('business', 'Business', 25000, 67500,  250000,
   999, 999, 2147483647, true,
   '["multiShop","advancedReports","csvExport","finances","apiIntegration"]'::jsonb,
   0, 3)
ON CONFLICT (name) DO UPDATE SET
  label              = EXCLUDED.label,
  max_shops          = EXCLUDED.max_shops,
  max_users_per_shop = EXCLUDED.max_users_per_shop,
  max_products       = EXCLUDED.max_products,
  offline_enabled    = EXCLUDED.offline_enabled,
  features           = EXCLUDED.features,
  trial_days         = EXCLUDED.trial_days,
  sort_order         = EXCLUDED.sort_order;

-- ── 2. Table subscriptions ─────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS subscriptions (
  id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  plan_id UUID NOT NULL
);

-- FK (idempotent)
DO $fk$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='subs_user_fk') THEN
    ALTER TABLE subscriptions
      ADD CONSTRAINT subs_user_fk FOREIGN KEY (user_id)
      REFERENCES auth.users(id) ON DELETE CASCADE;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='subs_plan_fk') THEN
    ALTER TABLE subscriptions
      ADD CONSTRAINT subs_plan_fk FOREIGN KEY (plan_id)
      REFERENCES plans(id);
  END IF;
END $fk$;

-- Colonnes additionnelles (idempotent)
ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS billing_cycle TEXT;
ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS sub_status    TEXT;
ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS started_at    TIMESTAMPTZ DEFAULT now();
ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS expires_at    TIMESTAMPTZ;
ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS cancelled_at  TIMESTAMPTZ;
ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS amount_paid   NUMERIC(12,2) DEFAULT 0;
ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS payment_ref   TEXT;
ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS notes         TEXT;
ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS activated_by  UUID REFERENCES auth.users(id);
ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS is_annual     BOOLEAN DEFAULT false;
ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS created_at    TIMESTAMPTZ DEFAULT now();

-- Contraintes CHECK (idempotent)
DO $chk$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname='subs_billing_cycle_chk')
  THEN ALTER TABLE subscriptions DROP CONSTRAINT subs_billing_cycle_chk;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname='subs_status_chk')
  THEN ALTER TABLE subscriptions DROP CONSTRAINT subs_status_chk;
  END IF;
END $chk$;

ALTER TABLE subscriptions
  ADD CONSTRAINT subs_billing_cycle_chk
  CHECK (billing_cycle IN ('monthly','quarterly','yearly'));

ALTER TABLE subscriptions
  ADD CONSTRAINT subs_status_chk
  CHECK (sub_status IN ('active','trial','expired','cancelled'));

-- Trigger pour maintenir is_annual cohérent avec billing_cycle.
DROP TRIGGER IF EXISTS trg_subs_set_is_annual ON subscriptions;
DROP FUNCTION IF EXISTS public.subscriptions_set_is_annual();
CREATE OR REPLACE FUNCTION public.subscriptions_set_is_annual()
RETURNS TRIGGER LANGUAGE plpgsql AS $set_annual$
BEGIN
  NEW.is_annual := (NEW.billing_cycle = 'yearly');
  RETURN NEW;
END;
$set_annual$;

CREATE TRIGGER trg_subs_set_is_annual
BEFORE INSERT OR UPDATE OF billing_cycle ON subscriptions
FOR EACH ROW EXECUTE FUNCTION public.subscriptions_set_is_annual();

-- Index pour les requêtes fréquentes
CREATE INDEX IF NOT EXISTS idx_subs_user        ON subscriptions(user_id);
CREATE INDEX IF NOT EXISTS idx_subs_status      ON subscriptions(sub_status);
CREATE INDEX IF NOT EXISTS idx_subs_user_active ON subscriptions(user_id, sub_status, expires_at DESC);

-- Empêcher d'avoir plus d'un abonnement actif/trial par user
CREATE UNIQUE INDEX IF NOT EXISTS idx_subs_one_active_per_user
  ON subscriptions(user_id) WHERE sub_status IN ('active','trial');

-- ── 3. RLS ─────────────────────────────────────────────────────────────────
ALTER TABLE plans         ENABLE ROW LEVEL SECURITY;
ALTER TABLE subscriptions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS plans_select ON plans;
CREATE POLICY plans_select ON plans FOR SELECT USING (true);

DROP POLICY IF EXISTS plans_write ON plans;
CREATE POLICY plans_write ON plans FOR ALL
  USING       (EXISTS(SELECT 1 FROM profiles WHERE id=auth.uid() AND is_super_admin=true))
  WITH CHECK  (EXISTS(SELECT 1 FROM profiles WHERE id=auth.uid() AND is_super_admin=true));

DROP POLICY IF EXISTS subs_select ON subscriptions;
CREATE POLICY subs_select ON subscriptions FOR SELECT
  USING (
    user_id = auth.uid()
    OR EXISTS(SELECT 1 FROM profiles WHERE id=auth.uid() AND is_super_admin=true)
  );

DROP POLICY IF EXISTS subs_write ON subscriptions;
CREATE POLICY subs_write ON subscriptions FOR ALL
  USING       (EXISTS(SELECT 1 FROM profiles WHERE id=auth.uid() AND is_super_admin=true))
  WITH CHECK  (EXISTS(SELECT 1 FROM profiles WHERE id=auth.uid() AND is_super_admin=true));

-- ── 4. RPC get_user_plan ───────────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.get_user_plan(UUID);
CREATE OR REPLACE FUNCTION public.get_user_plan(p_user_id UUID)
RETURNS TABLE (
  plan_name           TEXT,
  offline_enabled     BOOLEAN,
  max_shops           INT,
  max_users_per_shop  INT,
  max_products        INT,
  features            JSONB,
  sub_status          TEXT,
  expires_at          TIMESTAMPTZ,
  is_blocked          BOOLEAN
) LANGUAGE plpgsql STABLE SECURITY DEFINER AS $get_plan$
BEGIN
  RETURN QUERY
  SELECT
    COALESCE(p.name, 'none')                 AS plan_name,
    COALESCE(p.offline_enabled, false)        AS offline_enabled,
    COALESCE(p.max_shops, 0)                 AS max_shops,
    COALESCE(p.max_users_per_shop, 0)         AS max_users_per_shop,
    COALESCE(p.max_products, 0)               AS max_products,
    COALESCE(p.features, '[]'::jsonb)         AS features,
    COALESCE(s.sub_status, 'none')            AS sub_status,
    s.expires_at                               AS expires_at,
    COALESCE(pr.is_blocked, false)            AS is_blocked
  FROM profiles pr
  LEFT JOIN LATERAL (
    SELECT * FROM subscriptions
     WHERE user_id = p_user_id
       AND sub_status IN ('active','trial')
     ORDER BY expires_at DESC
     LIMIT 1
  ) s ON true
  LEFT JOIN plans p ON p.id = s.plan_id
  WHERE pr.id = p_user_id;
END;
$get_plan$;

GRANT EXECUTE ON FUNCTION public.get_user_plan(UUID) TO authenticated;

-- ── 5. Trigger : trial automatique à la création d'un profil ───────────────
DROP TRIGGER IF EXISTS trg_trial_on_profile_insert ON profiles;
DROP FUNCTION IF EXISTS public.create_trial_subscription();
CREATE OR REPLACE FUNCTION public.create_trial_subscription()
RETURNS TRIGGER LANGUAGE plpgsql AS $create_trial$
DECLARE
  v_plan_id     UUID;
  v_trial_days  INT;
BEGIN
  SELECT id, trial_days
    INTO v_plan_id, v_trial_days
    FROM plans
   WHERE name = 'trial' AND trial_days > 0
   LIMIT 1;

  IF v_plan_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF EXISTS (
    SELECT 1 FROM subscriptions
     WHERE user_id = NEW.id
       AND sub_status IN ('active','trial')
  ) THEN
    RETURN NEW;
  END IF;

  INSERT INTO subscriptions
      (user_id, plan_id, billing_cycle, sub_status,
       started_at, expires_at, amount_paid)
  VALUES
      (NEW.id, v_plan_id, 'monthly', 'trial',
       now(), now() + (v_trial_days || ' days')::INTERVAL, 0);

  RETURN NEW;
END;
$create_trial$;

CREATE TRIGGER trg_trial_on_profile_insert
AFTER INSERT ON profiles
FOR EACH ROW EXECUTE FUNCTION public.create_trial_subscription();

-- ── 6. Fonction utilitaire : marquer les subscriptions expirées ────────────
DROP FUNCTION IF EXISTS public.expire_subscriptions();
CREATE OR REPLACE FUNCTION public.expire_subscriptions()
RETURNS INT LANGUAGE plpgsql AS $expire$
DECLARE v_count INT;
BEGIN
  UPDATE subscriptions
     SET sub_status = 'expired'
   WHERE sub_status IN ('active','trial')
     AND expires_at < now();
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$expire$;

GRANT EXECUTE ON FUNCTION public.expire_subscriptions() TO authenticated;
