-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_076_dev_switch_plan_quarterly.sql
--
-- Ajoute le cycle « quarterly » (trimestriel = 90 jours) à la RPC
-- dev_switch_plan, sinon le nouveau sélecteur trimestriel de la page
-- abonnement échoue ('Cycle invalide').
--
-- Identique à hotfix_023 + :
--   • accepte 'quarterly' (90 jours) ;
--   • billing_cycle 'trial' → stocké 'monthly' pour respecter la
--     contrainte subs_billing_cycle_chk (IN monthly|quarterly|yearly)
--     ajoutée par hotfix_017 (sub_status reste 'trial').
--
-- ⚠ Inchangé (cf. hotfix_023) : cette RPC reste ouverte à tout utilisateur
--   authentifié. À restreindre à is_super_admin AVANT l'ouverture
--   commerciale (cf. project_prod_readiness).
--
-- 100 % idempotent (CREATE OR REPLACE).
-- ════════════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS public.dev_switch_plan(TEXT, TEXT);
CREATE OR REPLACE FUNCTION public.dev_switch_plan(
  p_plan_name TEXT,
  p_cycle     TEXT DEFAULT 'monthly'
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $dev_switch$
DECLARE
  v_uid          UUID := auth.uid();
  v_plan_id      UUID;
  v_days         INT;
  v_existing     UUID;
  v_now          TIMESTAMPTZ := now();
  v_expires      TIMESTAMPTZ;
  v_billing      TEXT;
  v_status       TEXT;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Non authentifié' USING ERRCODE = '42501';
  END IF;

  IF p_cycle NOT IN ('monthly','quarterly','yearly','trial') THEN
    RAISE EXCEPTION 'Cycle invalide (monthly|quarterly|yearly|trial)'
      USING ERRCODE = '22023';
  END IF;

  SELECT id INTO v_plan_id FROM plans WHERE name = p_plan_name LIMIT 1;
  IF v_plan_id IS NULL THEN
    RAISE EXCEPTION 'Plan "%": introuvable', p_plan_name USING ERRCODE = '22023';
  END IF;

  v_days := CASE p_cycle
    WHEN 'yearly'    THEN 365
    WHEN 'quarterly' THEN 90
    WHEN 'monthly'   THEN 30
    WHEN 'trial'     THEN 365   -- en dev on veut un trial long
    ELSE 30
  END;
  v_expires := v_now + (v_days || ' days')::INTERVAL;

  -- billing_cycle doit respecter subs_billing_cycle_chk (monthly|quarterly|
  -- yearly). Le pseudo-cycle 'trial' est donc stocké 'monthly' ; c'est
  -- sub_status='trial' qui marque l'essai.
  v_billing := CASE WHEN p_cycle = 'trial' THEN 'monthly' ELSE p_cycle END;
  v_status  := CASE WHEN p_cycle = 'trial' THEN 'trial'   ELSE 'active'  END;

  SELECT id INTO v_existing
    FROM subscriptions
   WHERE user_id = v_uid
     AND sub_status IN ('active','trial')
   ORDER BY expires_at DESC
   LIMIT 1;

  IF v_existing IS NOT NULL THEN
    UPDATE subscriptions
       SET plan_id        = v_plan_id,
           billing_cycle  = v_billing,
           sub_status     = v_status,
           started_at     = v_now,
           expires_at     = v_expires,
           amount_paid    = 0
     WHERE id = v_existing;
  ELSE
    INSERT INTO subscriptions
        (user_id, plan_id, billing_cycle, sub_status,
         started_at, expires_at, amount_paid)
    VALUES
        (v_uid, v_plan_id, v_billing, v_status,
         v_now, v_expires, 0);
  END IF;

  RETURN jsonb_build_object(
    'plan',        p_plan_name,
    'cycle',       p_cycle,
    'expires_at',  v_expires,
    'switched_at', v_now
  );
END;
$dev_switch$;

GRANT EXECUTE ON FUNCTION public.dev_switch_plan(TEXT, TEXT) TO authenticated;

-- Vérif : SELECT public.dev_switch_plan('starter','quarterly');
--   → JSON avec expires_at ≈ now()+90j, et la ligne subscriptions a
--     billing_cycle='quarterly', sub_status='active'.
