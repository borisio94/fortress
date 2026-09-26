-- ═══════════════════════════════════════════════════════════════════════════
-- hotfix_135 — sa_start_trial : le super-admin DÉMARRE (ou relance) un essai
--
-- CONTEXTE : `extend_trial` (hotfix_089) PROLONGE un essai existant mais échoue
-- s'il n'y en a pas (« aucun abonnement actif/essai »). Les essais n'étaient
-- créés qu'à l'auto-inscription (hotfix_020). Cette RPC permet au SA de démarrer
-- un essai pour n'importe quel propriétaire — nouveau OU expiré.
--
-- MODÈLE : l'essai = plan « trial » (accès Business pendant l'essai, cf.
-- plans_v3). On met `plan_id` = plan essai + `snap = NULL` : `get_user_plan`
-- (hotfix_114) retombe alors sur les quotas du plan via `plan_id`, EXACTEMENT
-- comme un essai d'inscription. Durée choisie par le SA (jours).
--
-- SÉCURITÉ : SECURITY DEFINER + `public._is_super_admin()` (comme extend_trial).
-- Débloque le compte (prof_status='active', is_blocked=false). Trace dans
-- activity_logs (action 'trial_started'). Idempotent (réexécutable).
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.sa_start_trial(
  p_shop_id TEXT,
  p_days    INT
) RETURNS TIMESTAMPTZ
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $sa_start_trial$
DECLARE
  v_owner    UUID;
  v_name     TEXT;
  v_email    TEXT;
  v_plan_id  UUID;
  v_sub_id   UUID;
  v_new_exp  TIMESTAMPTZ;
BEGIN
  -- 1) Réservé super-admin.
  IF NOT public._is_super_admin() THEN
    RAISE EXCEPTION 'forbidden: super-admin requis' USING ERRCODE = '42501';
  END IF;
  IF COALESCE(p_days, 0) <= 0 THEN
    RAISE EXCEPTION 'nombre de jours invalide' USING ERRCODE = 'P0001';
  END IF;

  -- 2) Propriétaire de la boutique cible.
  SELECT owner_id::uuid, name INTO v_owner, v_name
    FROM public.shops WHERE id = p_shop_id;
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'boutique ou propriétaire introuvable' USING ERRCODE = 'P0002';
  END IF;

  -- 3) Plan « essai » (= accès Business pendant l'essai, même lookup que le
  --    trigger d'inscription hotfix_020).
  SELECT id INTO v_plan_id
    FROM public.plans WHERE name = 'trial' AND trial_days > 0 LIMIT 1;
  IF v_plan_id IS NULL THEN
    RAISE EXCEPTION 'plan essai introuvable' USING ERRCODE = 'P0002';
  END IF;

  v_new_exp := NOW() + (p_days || ' days')::interval;

  -- 4) Réinitialise l'abonnement du propriétaire en ESSAI (la plus récente
  --    ligne, quel que soit son statut — on relance même un essai expiré).
  SELECT id INTO v_sub_id
    FROM public.subscriptions
   WHERE user_id = v_owner
   ORDER BY expires_at DESC NULLS LAST, started_at DESC
   LIMIT 1;

  IF v_sub_id IS NULL THEN
    INSERT INTO public.subscriptions
      (user_id, plan_id, billing_cycle, sub_status,
       started_at, expires_at, amount_paid)
    VALUES
      (v_owner, v_plan_id, 'monthly', 'trial',
       NOW(), v_new_exp, 0);
  ELSE
    -- `plan_snapshot = NULL` : le trigger `snapshot_plan_on_subscription`
    -- (BEFORE UPDATE OF plan_id, hotfix_114) le re-remplit depuis le NOUVEAU
    -- plan (essai = Business) → quotas corrects. Sans ce reset, l'ancien
    -- snapshot resterait figé (mauvais quotas).
    -- NB : le déblocage se fait via profiles.prof_status (étape 5) — la table
    -- `subscriptions` n'a PAS de colonne is_blocked dans cette base.
    UPDATE public.subscriptions
       SET plan_id       = v_plan_id,
           billing_cycle = 'monthly',
           sub_status    = 'trial',
           started_at    = NOW(),
           expires_at    = v_new_exp,
           amount_paid   = 0,
           plan_snapshot = NULL
     WHERE id = v_sub_id;
  END IF;

  -- 5) Débloque le compte propriétaire (retour d'accès immédiat).
  UPDATE public.profiles
     SET prof_status = 'active', blocked_at = NULL
   WHERE id = v_owner;

  -- 6) Traçabilité.
  SELECT email INTO v_email FROM public.profiles
   WHERE id::text = auth.uid()::text;
  INSERT INTO public.activity_logs
    (actor_id, actor_email, action, target_type, target_id, target_label,
     shop_id, details)
  VALUES
    (auth.uid(), v_email, 'trial_started', 'shop', p_shop_id, v_name,
     p_shop_id, jsonb_build_object('days', p_days, 'expires_at', v_new_exp));

  RETURN v_new_exp;
END;
$sa_start_trial$;

GRANT EXECUTE ON FUNCTION public.sa_start_trial(TEXT, INT) TO authenticated;

-- Vérif rapide (optionnel) :
-- SELECT public.sa_start_trial('<shop_id>', 14);
