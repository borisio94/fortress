-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_089_super_admin_pr2.sql — Super-admin PR-2
--
-- SA-3 : prolonger l'essai (ou la période active) d'une boutique. Les
--        abonnements sont par `user_id` (le propriétaire), pas par shop —
--        on résout donc l'owner de la boutique puis on étend `expires_at`
--        de sa subscription courante (active/trial).
-- SA-4 : historique des paiements (table dédiée `payment_records`) +
--        enregistrement d'un paiement, avec activation optionnelle du plan.
--
-- Idempotent. Réservé super-admin via public._is_super_admin(). RPC en
-- SECURITY DEFINER (bypass RLS) + vérification d'autorisation interne.
-- ════════════════════════════════════════════════════════════════════════════

-- ── SA-3 : RPC extend_trial ─────────────────────────────────────────────────
-- Étend `expires_at` de la subscription courante du propriétaire de la
-- boutique de `p_days` jours, à partir de MAX(expires_at, NOW()) pour ne
-- jamais raccourcir une période déjà plus longue. Retourne la nouvelle
-- date d'expiration.
CREATE OR REPLACE FUNCTION public.extend_trial(
  p_shop_id TEXT,
  p_days    INT
) RETURNS TIMESTAMPTZ
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $extend_trial$
DECLARE
  v_owner   UUID;
  v_sub_id  UUID;
  v_new_exp TIMESTAMPTZ;
  v_email   TEXT;
  v_name    TEXT;
BEGIN
  IF NOT public._is_super_admin() THEN
    RAISE EXCEPTION 'forbidden: super-admin requis' USING ERRCODE = '42501';
  END IF;
  IF COALESCE(p_days, 0) <= 0 THEN
    RAISE EXCEPTION 'nombre de jours invalide' USING ERRCODE = 'P0001';
  END IF;

  SELECT owner_id::uuid, name INTO v_owner, v_name
    FROM public.shops WHERE id = p_shop_id;
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'boutique ou propriétaire introuvable' USING ERRCODE = 'P0002';
  END IF;

  -- Subscription courante du propriétaire (active ou trial, la plus récente).
  SELECT id INTO v_sub_id
    FROM public.subscriptions
   WHERE user_id = v_owner AND sub_status IN ('active', 'trial')
   ORDER BY expires_at DESC NULLS LAST, started_at DESC
   LIMIT 1;
  IF v_sub_id IS NULL THEN
    RAISE EXCEPTION 'aucun abonnement actif/essai pour ce propriétaire'
      USING ERRCODE = 'P0002';
  END IF;

  UPDATE public.subscriptions
     SET expires_at = GREATEST(COALESCE(expires_at, NOW()), NOW())
                      + (p_days || ' days')::interval
   WHERE id = v_sub_id
   RETURNING expires_at INTO v_new_exp;

  SELECT email INTO v_email FROM public.profiles
   WHERE id::text = auth.uid()::text;
  INSERT INTO public.activity_logs
    (actor_id, actor_email, action, target_type, target_id, target_label,
     shop_id, details)
  VALUES
    (auth.uid(), v_email, 'trial_extended', 'shop', p_shop_id, v_name,
     p_shop_id, jsonb_build_object('days', p_days,
                                   'new_expires_at', v_new_exp));

  RETURN v_new_exp;
END;
$extend_trial$;

-- ── SA-4 : table payment_records ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.payment_records (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id    TEXT NOT NULL REFERENCES public.shops(id) ON DELETE CASCADE,
  plan_id    UUID REFERENCES public.plans(id),
  amount     NUMERIC(12,2) NOT NULL DEFAULT 0,
  currency   TEXT NOT NULL DEFAULT 'XAF',
  paid_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  method     TEXT,          -- cash | mobile_money | transfer | other
  reference  TEXT,
  note       TEXT,
  created_by UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS payment_records_shop_idx
  ON public.payment_records(shop_id, paid_at DESC);

ALTER TABLE public.payment_records ENABLE ROW LEVEL SECURITY;

-- Lecture : super-admin (tout) OU membre/owner de la boutique concernée.
DROP POLICY IF EXISTS "payment_records_read" ON public.payment_records;
CREATE POLICY "payment_records_read" ON public.payment_records
  FOR SELECT TO authenticated
  USING (
    public._is_super_admin()
    OR shop_id IN (
      SELECT s.id::text FROM public.shops s
       WHERE s.owner_id::text = auth.uid()::text
      UNION
      SELECT m.shop_id::text FROM public.shop_memberships m
       WHERE m.user_id::text = auth.uid()::text
    )
  );
-- Écriture : uniquement via RPC SECURITY DEFINER (record_payment).

-- ── SA-4 : RPC record_payment ───────────────────────────────────────────────
-- Enregistre un paiement. Si p_activate_plan = true ET p_plan_id fourni,
-- bascule la subscription du propriétaire sur ce plan (active) en étendant
-- expires_at de p_months mois (défaut 1).
CREATE OR REPLACE FUNCTION public.record_payment(
  p_shop_id       TEXT,
  p_plan_id       UUID,
  p_amount        NUMERIC,
  p_currency      TEXT,
  p_method        TEXT,
  p_reference     TEXT,
  p_note          TEXT,
  p_activate_plan BOOLEAN DEFAULT false,
  p_months        INT     DEFAULT 1
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $record_payment$
DECLARE
  v_id     UUID;
  v_owner  UUID;
  v_email  TEXT;
  v_name   TEXT;
  v_sub_id UUID;
BEGIN
  IF NOT public._is_super_admin() THEN
    RAISE EXCEPTION 'forbidden: super-admin requis' USING ERRCODE = '42501';
  END IF;

  SELECT owner_id::uuid, name INTO v_owner, v_name
    FROM public.shops WHERE id = p_shop_id;
  IF v_name IS NULL THEN
    RAISE EXCEPTION 'boutique introuvable' USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO public.payment_records
    (shop_id, plan_id, amount, currency, method, reference, note, created_by)
  VALUES
    (p_shop_id, p_plan_id, COALESCE(p_amount, 0),
     COALESCE(NULLIF(TRIM(p_currency), ''), 'XAF'),
     p_method, p_reference, p_note, auth.uid())
  RETURNING id INTO v_id;

  -- Activation optionnelle du plan sur la subscription du propriétaire.
  IF p_activate_plan AND p_plan_id IS NOT NULL AND v_owner IS NOT NULL THEN
    SELECT id INTO v_sub_id
      FROM public.subscriptions
     WHERE user_id = v_owner AND sub_status IN ('active', 'trial')
     ORDER BY expires_at DESC NULLS LAST, started_at DESC
     LIMIT 1;
    IF v_sub_id IS NULL THEN
      INSERT INTO public.subscriptions
        (user_id, plan_id, sub_status, billing_cycle, started_at,
         expires_at, amount_paid, payment_ref, activated_by)
      VALUES
        (v_owner, p_plan_id, 'active', 'monthly', NOW(),
         NOW() + (COALESCE(p_months, 1) || ' months')::interval,
         COALESCE(p_amount, 0), p_reference, auth.uid());
    ELSE
      UPDATE public.subscriptions
         SET plan_id      = p_plan_id,
             sub_status   = 'active',
             expires_at   = GREATEST(COALESCE(expires_at, NOW()), NOW())
                            + (COALESCE(p_months, 1) || ' months')::interval,
             amount_paid  = COALESCE(amount_paid, 0) + COALESCE(p_amount, 0),
             payment_ref  = p_reference,
             activated_by = auth.uid(),
             cancelled_at = NULL
       WHERE id = v_sub_id;
    END IF;
  END IF;

  SELECT email INTO v_email FROM public.profiles
   WHERE id::text = auth.uid()::text;
  INSERT INTO public.activity_logs
    (actor_id, actor_email, action, target_type, target_id, target_label,
     shop_id, details)
  VALUES
    (auth.uid(), v_email, 'payment_recorded', 'shop', p_shop_id, v_name,
     p_shop_id, jsonb_build_object('amount', p_amount, 'method', p_method,
                                   'activated', p_activate_plan));

  RETURN v_id;
END;
$record_payment$;

-- ── Rechargement du cache de schéma PostgREST ───────────────────────────────
NOTIFY pgrst, 'reload schema';
