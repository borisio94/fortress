-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_088_super_admin_pr1.sql — Super-admin PR-1
--
-- SA-1 : suspendre / réactiver une boutique (distinct du toggle `is_active`
--        de l'owner). `status='suspended'` bloque TOTALEMENT l'accès des
--        membres (écran "Compte suspendu" côté Flutter). Réservé super-admin.
-- SA-2 : CRUD des plans d'abonnement (la table `plans` existe déjà —
--        cf. hotfix_017). RPC d'upsert réservée super-admin.
--
-- Idempotent : ADD COLUMN IF NOT EXISTS + CREATE OR REPLACE FUNCTION +
-- DROP POLICY IF EXISTS. Réservé super-admin via public._is_super_admin()
-- (cf. hotfix_041). Toutes les RPC sont SECURITY DEFINER (bypass RLS) et
-- vérifient l'autorisation en interne.
-- ════════════════════════════════════════════════════════════════════════════

-- ── SA-1 : colonnes de suspension sur shops ─────────────────────────────────
ALTER TABLE public.shops
  ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'active';
-- Contrainte CHECK ajoutée séparément (idempotent via DO block — un simple
-- ADD CONSTRAINT échoue à la 2ᵉ exécution).
DO $chk$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'shops_status_check'
  ) THEN
    ALTER TABLE public.shops
      ADD CONSTRAINT shops_status_check
      CHECK (status IN ('active', 'suspended'));
  END IF;
END $chk$;
ALTER TABLE public.shops ADD COLUMN IF NOT EXISTS suspended_at     TIMESTAMPTZ;
ALTER TABLE public.shops ADD COLUMN IF NOT EXISTS suspended_reason TEXT;

-- ── SA-1 : RPC suspend_shop ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.suspend_shop(
  p_shop_id TEXT,
  p_reason  TEXT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $suspend$
DECLARE
  v_email TEXT;
  v_name  TEXT;
BEGIN
  IF NOT public._is_super_admin() THEN
    RAISE EXCEPTION 'forbidden: super-admin requis' USING ERRCODE = '42501';
  END IF;
  IF COALESCE(TRIM(p_reason), '') = '' THEN
    RAISE EXCEPTION 'motif requis' USING ERRCODE = 'P0001';
  END IF;

  UPDATE public.shops
     SET status           = 'suspended',
         suspended_at     = NOW(),
         suspended_reason = p_reason
   WHERE id = p_shop_id
   RETURNING name INTO v_name;

  IF v_name IS NULL THEN
    RAISE EXCEPTION 'boutique introuvable' USING ERRCODE = 'P0002';
  END IF;

  SELECT email INTO v_email FROM public.profiles
   WHERE id::text = auth.uid()::text;

  INSERT INTO public.activity_logs
    (actor_id, actor_email, action, target_type, target_id, target_label,
     shop_id, details)
  VALUES
    (auth.uid(), v_email, 'shop_suspended', 'shop', p_shop_id, v_name,
     p_shop_id, jsonb_build_object('reason', p_reason));
END;
$suspend$;

-- ── SA-1 : RPC reactivate_shop ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.reactivate_shop(
  p_shop_id TEXT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $reactivate$
DECLARE
  v_email TEXT;
  v_name  TEXT;
BEGIN
  IF NOT public._is_super_admin() THEN
    RAISE EXCEPTION 'forbidden: super-admin requis' USING ERRCODE = '42501';
  END IF;

  UPDATE public.shops
     SET status           = 'active',
         suspended_at     = NULL,
         suspended_reason = NULL
   WHERE id = p_shop_id
   RETURNING name INTO v_name;

  IF v_name IS NULL THEN
    RAISE EXCEPTION 'boutique introuvable' USING ERRCODE = 'P0002';
  END IF;

  SELECT email INTO v_email FROM public.profiles
   WHERE id::text = auth.uid()::text;

  INSERT INTO public.activity_logs
    (actor_id, actor_email, action, target_type, target_id, target_label,
     shop_id, details)
  VALUES
    (auth.uid(), v_email, 'shop_reactivated', 'shop', p_shop_id, v_name,
     p_shop_id, '{}'::jsonb);
END;
$reactivate$;

-- ── SA-2 : RPC upsert_plan ──────────────────────────────────────────────────
-- p_id NULL → création (id auto). p_id fourni → mise à jour (permet de
-- renommer). Retourne l'id du plan créé/modifié.
CREATE OR REPLACE FUNCTION public.upsert_plan(
  p_id                 UUID,
  p_name               TEXT,
  p_label              TEXT,
  p_price_monthly      NUMERIC,
  p_price_quarterly    NUMERIC,
  p_price_yearly       NUMERIC,
  p_max_products       INT,
  p_max_users_per_shop INT,
  p_max_shops          INT,
  p_features           JSONB,
  p_offline_enabled    BOOLEAN,
  p_trial_days         INT,
  p_is_active          BOOLEAN
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $upsert_plan$
DECLARE
  v_id    UUID;
  v_email TEXT;
BEGIN
  IF NOT public._is_super_admin() THEN
    RAISE EXCEPTION 'forbidden: super-admin requis' USING ERRCODE = '42501';
  END IF;
  IF COALESCE(TRIM(p_name), '') = '' THEN
    RAISE EXCEPTION 'nom du plan requis' USING ERRCODE = 'P0001';
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO public.plans
      (name, label, price_monthly, price_quarterly, price_yearly,
       max_products, max_users_per_shop, max_shops, features,
       offline_enabled, trial_days, is_active)
    VALUES
      (p_name, p_label, COALESCE(p_price_monthly, 0),
       COALESCE(p_price_quarterly, 0), COALESCE(p_price_yearly, 0),
       COALESCE(p_max_products, 50), COALESCE(p_max_users_per_shop, 1),
       COALESCE(p_max_shops, 1), COALESCE(p_features, '[]'::jsonb),
       COALESCE(p_offline_enabled, false), COALESCE(p_trial_days, 0),
       COALESCE(p_is_active, true))
    RETURNING id INTO v_id;
  ELSE
    UPDATE public.plans
       SET name               = p_name,
           label              = p_label,
           price_monthly      = COALESCE(p_price_monthly, price_monthly),
           price_quarterly    = COALESCE(p_price_quarterly, price_quarterly),
           price_yearly       = COALESCE(p_price_yearly, price_yearly),
           max_products       = COALESCE(p_max_products, max_products),
           max_users_per_shop = COALESCE(p_max_users_per_shop, max_users_per_shop),
           max_shops          = COALESCE(p_max_shops, max_shops),
           features           = COALESCE(p_features, features),
           offline_enabled    = COALESCE(p_offline_enabled, offline_enabled),
           trial_days         = COALESCE(p_trial_days, trial_days),
           is_active          = COALESCE(p_is_active, is_active)
     WHERE id = p_id
     RETURNING id INTO v_id;
    IF v_id IS NULL THEN
      RAISE EXCEPTION 'plan introuvable' USING ERRCODE = 'P0002';
    END IF;
  END IF;

  SELECT email INTO v_email FROM public.profiles
   WHERE id::text = auth.uid()::text;
  INSERT INTO public.activity_logs
    (actor_id, actor_email, action, target_type, target_id, target_label, details)
  VALUES
    (auth.uid(), v_email,
     CASE WHEN p_id IS NULL THEN 'plan_created' ELSE 'plan_updated' END,
     'plan', v_id::text, p_label, jsonb_build_object('name', p_name));

  RETURN v_id;
END;
$upsert_plan$;

-- ── RLS plans : lecture pour tous les authentifiés, écriture via RPC only ───
ALTER TABLE public.plans ENABLE ROW LEVEL SECURITY;
DO $plans_read$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
     WHERE tablename = 'plans' AND policyname = 'plans_read_all'
  ) THEN
    CREATE POLICY "plans_read_all" ON public.plans
      FOR SELECT TO authenticated, anon USING (true);
  END IF;
END $plans_read$;
-- Pas de policy INSERT/UPDATE/DELETE : seules les RPC SECURITY DEFINER
-- (upsert_plan) écrivent, après vérification _is_super_admin().

-- ── Rechargement du cache de schéma PostgREST ───────────────────────────────
NOTIFY pgrst, 'reload schema';
