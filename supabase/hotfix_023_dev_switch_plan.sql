-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_023_dev_switch_plan.sql
--
-- DEV ONLY — Permet à un utilisateur authentifié de basculer librement entre
-- les plans (starter / pro / business / trial) sans intervention d'un super
-- admin. Bypass total du flux d'activation manuel.
--
-- ⚠ AVANT PROD : retirer cette RPC ou la restreindre à `is_super_admin=true`,
--   sinon n'importe quel utilisateur peut s'auto-attribuer un plan business.
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
  v_uid       UUID := auth.uid();
  v_plan_id   UUID;
  v_days      INT;
  v_existing  UUID;
  v_now       TIMESTAMPTZ := now();
  v_expires   TIMESTAMPTZ;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Non authentifié' USING ERRCODE = '42501';
  END IF;

  IF p_cycle NOT IN ('monthly','yearly','trial') THEN
    RAISE EXCEPTION 'Cycle invalide (monthly|yearly|trial)'
      USING ERRCODE = '22023';
  END IF;

  -- Résoudre l'id du plan par son nom
  SELECT id INTO v_plan_id FROM plans WHERE name = p_plan_name LIMIT 1;
  IF v_plan_id IS NULL THEN
    RAISE EXCEPTION 'Plan "%": introuvable', p_plan_name USING ERRCODE = '22023';
  END IF;

  -- Calcul de l'expiration selon le cycle
  v_days := CASE p_cycle
    WHEN 'yearly'  THEN 365
    WHEN 'monthly' THEN 30
    WHEN 'trial'   THEN 365  -- en dev on veut un trial long
    ELSE 30
  END;
  v_expires := v_now + (v_days || ' days')::INTERVAL;

  -- Upsert : remplace la subscription active courante (s'il y en a une)
  SELECT id INTO v_existing
    FROM subscriptions
   WHERE user_id = v_uid
     AND sub_status IN ('active','trial')
   ORDER BY expires_at DESC
   LIMIT 1;

  IF v_existing IS NOT NULL THEN
    UPDATE subscriptions
       SET plan_id        = v_plan_id,
           billing_cycle  = p_cycle,
           sub_status     = CASE WHEN p_cycle = 'trial' THEN 'trial' ELSE 'active' END,
           started_at     = v_now,
           expires_at     = v_expires,
           amount_paid    = 0
     WHERE id = v_existing;
  ELSE
    INSERT INTO subscriptions
        (user_id, plan_id, billing_cycle, sub_status,
         started_at, expires_at, amount_paid)
    VALUES
        (v_uid, v_plan_id, p_cycle,
         CASE WHEN p_cycle = 'trial' THEN 'trial' ELSE 'active' END,
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
