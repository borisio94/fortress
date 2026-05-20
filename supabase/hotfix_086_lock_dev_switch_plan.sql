-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_086_lock_dev_switch_plan.sql
--
-- Verrou super-admin sur dev_switch_plan (et dev_switch_plan_quarterly).
--
-- Contexte
-- ────────
-- Avant ce hotfix, la RPC `dev_switch_plan(plan_name, cycle)` était
-- `GRANT EXECUTE ... TO authenticated` (cf. hotfix_023:89 puis
-- hotfix_076:103). N'importe quel utilisateur connecté pouvait donc
-- s'auto-attribuer un plan business gratuit, contournant intégralement
-- le paywall et le flux d'activation manuel.
--
-- Les 2 fichiers précédents le signalaient explicitement :
--   « ⚠ AVANT PROD : retirer cette RPC ou la restreindre à
--    `is_super_admin=true`, sinon n'importe quel utilisateur peut
--    s'auto-attribuer un plan business. »
--
-- Ce hotfix applique la restriction sans toucher au reste de la logique
-- métier. La RPC reste callable (utile pour le super-admin Fortress qui
-- doit tester les plans en interne ou débloquer un compte client), mais
-- tout authenticated non super-admin reçoit `permission_denied` (42501).
--
-- Stratégie
-- ─────────
-- 1. CREATE OR REPLACE la signature existante en gardant la même API
--    publique (signature inchangée → aucun client cassé).
-- 2. Ajouter en TÊTE de la fonction :
--      IF NOT public._is_super_admin() THEN RAISE EXCEPTION ... END IF;
-- 3. REVOKE de PUBLIC + GRANT à authenticated (le check interne fait
--    le vrai filtrage — le GRANT reste large car la RPC peut quand même
--    être appelée par tout authenticated, elle leur retournera juste
--    une erreur claire).
-- 4. Le reste du corps est strictement identique à hotfix_076 — c'est
--    la version courante (4 cycles : monthly|quarterly|yearly|trial).
--
-- Idempotent : DROP FUNCTION IF EXISTS + CREATE OR REPLACE.
-- Sûr à ré-exécuter.
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

  -- ── Verrou super-admin (hotfix_086) ───────────────────────────────────
  -- Auparavant : ouvert à tout authenticated → faille critique paywall.
  -- Désormais : la RPC retourne `permission_denied` à tout user non
  -- super-admin, peu importe le GRANT EXECUTE. SECURITY DEFINER fait
  -- exécuter la fonction avec les privilèges du owner (postgres), mais
  -- `auth.uid()` retourne toujours l'identité de l'appelant — le check
  -- `_is_super_admin()` (hotfix_041) lit profiles.is_super_admin en
  -- bypass RLS via son propre SECURITY DEFINER.
  IF NOT public._is_super_admin() THEN
    RAISE EXCEPTION 'permission_denied'
      USING ERRCODE = '42501',
            MESSAGE = 'dev_switch_plan est réservée au super-admin.',
            DETAIL  = jsonb_build_object('code', 'permission_denied',
                                         'rpc', 'dev_switch_plan')::text;
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

-- REVOKE de PUBLIC pour la propreté (le default sur les fonctions est
-- déjà EXECUTE TO PUBLIC pour les fonctions PLPGSQL, mais on l'expulse
-- explicitement). Le GRANT TO authenticated reste — le check
-- _is_super_admin() interne est ce qui protège vraiment.
REVOKE ALL ON FUNCTION public.dev_switch_plan(TEXT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.dev_switch_plan(TEXT, TEXT)
       TO authenticated;

-- ────────────────────────────────────────────────────────────────────────
-- Test manuel
-- ───────────
--   1) Avec un user NON super-admin :
--      SELECT public.dev_switch_plan('pro', 'monthly');
--      → ERROR 42501 « dev_switch_plan est réservée au super-admin. »
--   2) Avec le super-admin Fortress :
--      SELECT public.dev_switch_plan('pro', 'quarterly');
--      → JSON OK, ligne subscriptions mise à jour.
--   3) Re-jouer le hotfix : aucune erreur (idempotent).
-- ────────────────────────────────────────────────────────────────────────
-- Fin — hotfix_086_lock_dev_switch_plan.sql
