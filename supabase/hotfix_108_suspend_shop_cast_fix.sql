-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_108_suspend_shop_cast_fix.sql
--
-- Corrige les RPC suspend_shop / reactivate_shop (hotfix_088) qui plantaient
-- avec « column "shop_id" is of type uuid but expression is of type text »
-- (42804) : l'INSERT dans activity_logs mettait p_shop_id (TEXT) dans la
-- colonne activity_logs.shop_id (UUID). On caste p_shop_id::uuid.
--
-- Le WHERE sur shops est aussi rendu robuste (id::text = p_shop_id) pour
-- fonctionner quel que soit le type de shops.id.
--
-- Bug PRÉEXISTANT (hotfix_088) — la suspension n'avait jamais été testée.
-- Idempotent.
-- ════════════════════════════════════════════════════════════════════════════

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
   WHERE id::text = p_shop_id
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
     p_shop_id::uuid, jsonb_build_object('reason', p_reason));
END;
$suspend$;

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
   WHERE id::text = p_shop_id
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
     p_shop_id::uuid, '{}'::jsonb);
END;
$reactivate$;

NOTIFY pgrst, 'reload schema';
