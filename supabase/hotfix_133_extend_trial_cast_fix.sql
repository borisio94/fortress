-- ═════════════════════════════════════════════════════════════════════════════
-- hotfix_133 — `extend_trial` ET `record_payment` : cast uuid manquant
-- (même bug que hotfix_108).
--
-- Symptôme (super-admin → « Prolonger l'essai » ou « Enregistrer un paiement ») :
--   PostgrestException(message: column "shop_id" is of type uuid but
--   expression is of type text, code: 42804)
--
-- Cause : l'INSERT d'audit dans `public.activity_logs` mettait `p_shop_id`
-- (TEXT) dans la colonne `activity_logs.shop_id` (UUID) sans cast. hotfix_108
-- avait corrigé `suspend_shop` / `reactivate_shop` de la même façon, mais
-- `extend_trial` et `record_payment` (hotfix_089) étaient restés non corrigés.
--
-- Fix (identique à hotfix_108) :
--   • lookup boutique robuste : `WHERE id::text = p_shop_id`
--   • insert audit : `shop_id` = `p_shop_id::uuid`
-- (les ids de boutique sont des chaînes au format UUID, donc le cast est sûr.)
--   NB : `payment_records.shop_id` est TEXT → l'insert paiement reste sans cast ;
--        seul l'audit `activity_logs.shop_id` (UUID) exige `::uuid`.
--
-- Idempotent : CREATE OR REPLACE (conserve les privilèges existants ; GRANT
-- ré-affirmé par sécurité).
-- ═════════════════════════════════════════════════════════════════════════════

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

  -- Lookup robuste : compare en texte (les ids de boutique sont stockés en
  -- TEXT côté shops, mais on reste défensif si la colonne diverge).
  SELECT owner_id::uuid, name INTO v_owner, v_name
    FROM public.shops WHERE id::text = p_shop_id;
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

  -- target_id = TEXT (OK avec p_shop_id) ; shop_id = UUID → cast obligatoire.
  INSERT INTO public.activity_logs
    (actor_id, actor_email, action, target_type, target_id, target_label,
     shop_id, details)
  VALUES
    (auth.uid(), v_email, 'trial_extended', 'shop', p_shop_id, v_name,
     p_shop_id::uuid, jsonb_build_object('days', p_days,
                                         'new_expires_at', v_new_exp));

  RETURN v_new_exp;
END;
$extend_trial$;

GRANT EXECUTE ON FUNCTION public.extend_trial(text, int) TO authenticated;


-- ── record_payment : même cast manquant dans l'audit activity_logs ──────────
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
    FROM public.shops WHERE id::text = p_shop_id;
  IF v_name IS NULL THEN
    RAISE EXCEPTION 'boutique introuvable' USING ERRCODE = 'P0002';
  END IF;

  -- payment_records.shop_id est TEXT → pas de cast ici.
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
  -- shop_id = UUID → cast obligatoire (target_id = TEXT, OK).
  INSERT INTO public.activity_logs
    (actor_id, actor_email, action, target_type, target_id, target_label,
     shop_id, details)
  VALUES
    (auth.uid(), v_email, 'payment_recorded', 'shop', p_shop_id, v_name,
     p_shop_id::uuid, jsonb_build_object('amount', p_amount, 'method', p_method,
                                         'activated', p_activate_plan));

  RETURN v_id;
END;
$record_payment$;

GRANT EXECUTE ON FUNCTION public.record_payment(
  text, uuid, numeric, text, text, text, text, boolean, int) TO authenticated;

-- Rechargement du cache de schéma PostgREST.
NOTIFY pgrst, 'reload schema';
