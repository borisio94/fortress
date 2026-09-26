-- ═══════════════════════════════════════════════════════════════════════════
-- hotfix_136 — MODE GRATUIT GLOBAL (période de test de nouvelles fonctions)
--
-- Le super-admin bascule TOUTE l'application en « mode essai » : pendant cette
-- période, TOUS les comptes (anciens ET nouveaux) obtiennent l'accès Business
-- gratuit, quel que soit leur abonnement réel. Les comptes BLOQUÉS manuellement
-- (anti-abus) restent bloqués. Optionnellement, une date de fin auto-désactive.
--
-- Mécanisme : un flag serveur (table singleton `platform_config`) + un override
-- en tête de `get_user_plan` (source unique de vérité du plan). AUCUN changement
-- d'app nécessaire côté enforcement — tout passe par get_user_plan.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1) Table de config plateforme (une seule ligne, id=1) ───────────────────
CREATE TABLE IF NOT EXISTS public.platform_config (
  id                SMALLINT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  free_mode_enabled BOOLEAN     NOT NULL DEFAULT false,
  free_mode_until   TIMESTAMPTZ,               -- NULL = sans échéance
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by        UUID
);
INSERT INTO public.platform_config (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.platform_config ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS platform_config_read ON public.platform_config;
CREATE POLICY platform_config_read ON public.platform_config
  FOR SELECT TO authenticated USING (true);   -- lecture pour tous (flag public)
GRANT SELECT ON public.platform_config TO authenticated;

-- ── 2) Helper : le mode gratuit est-il actif ? ──────────────────────────────
CREATE OR REPLACE FUNCTION public.free_mode_active()
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT COALESCE(free_mode_enabled, false)
         AND (free_mode_until IS NULL OR free_mode_until > now())
    FROM public.platform_config WHERE id = 1;
$$;
GRANT EXECUTE ON FUNCTION public.free_mode_active() TO authenticated;

-- ── 3) RPC SA : activer / désactiver le mode gratuit ────────────────────────
CREATE OR REPLACE FUNCTION public.sa_set_free_mode(
  p_enabled BOOLEAN,
  p_until   TIMESTAMPTZ DEFAULT NULL
) RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_email TEXT;
BEGIN
  IF NOT public._is_super_admin() THEN
    RAISE EXCEPTION 'forbidden: super-admin requis' USING ERRCODE = '42501';
  END IF;
  UPDATE public.platform_config
     SET free_mode_enabled = COALESCE(p_enabled, false),
         free_mode_until   = p_until,
         updated_at        = now(),
         updated_by        = auth.uid()
   WHERE id = 1;

  SELECT email INTO v_email FROM public.profiles WHERE id::text = auth.uid()::text;
  INSERT INTO public.activity_logs
    (actor_id, actor_email, action, target_type, target_id, target_label, details)
  VALUES
    (auth.uid(), v_email,
     CASE WHEN COALESCE(p_enabled,false) THEN 'free_mode_on' ELSE 'free_mode_off' END,
     'platform', 'global', 'Mode gratuit global',
     jsonb_build_object('enabled', COALESCE(p_enabled,false), 'until', p_until));

  RETURN public.free_mode_active();
END;
$$;
GRANT EXECUTE ON FUNCTION public.sa_set_free_mode(BOOLEAN, TIMESTAMPTZ) TO authenticated;

-- ── 4) get_user_plan : override MODE GRATUIT en tête ────────────────────────
-- Signature IDENTIQUE à hotfix_114. Quand le mode gratuit est actif, renvoie le
-- plan Business pour TOUS (statut 'trial', échéance = free_mode_until), sauf
-- is_blocked qui reste piloté par prof_status (les comptes bloqués le restent).
CREATE OR REPLACE FUNCTION public.get_user_plan(p_user_id UUID)
RETURNS TABLE (
  plan_name           TEXT,
  offline_enabled     BOOLEAN,
  max_shops           INT,
  max_users_per_shop  INT,
  max_products        INT,
  max_partner_depots  INT,
  max_employees_per_shop INT,
  max_warehouses      INT,
  features            JSONB,
  sub_status          TEXT,
  expires_at          TIMESTAMPTZ,
  is_blocked          BOOLEAN
) LANGUAGE plpgsql STABLE SECURITY DEFINER AS $get_plan$
BEGIN
  -- ► MODE GRATUIT GLOBAL : accès Business pour tout le monde.
  IF public.free_mode_active() THEN
    RETURN QUERY
    SELECT
      p.name,
      COALESCE(p.offline_enabled, true),
      COALESCE(p.max_shops, 0),
      COALESCE(p.max_users_per_shop, 0),
      COALESCE(p.max_products, 0),
      COALESCE(p.max_partner_depots_per_shop, 0),
      COALESCE(p.max_employees_per_shop, 0),
      COALESCE(p.max_warehouses, 0),
      COALESCE(p.features, '[]'::jsonb),
      'trial'::text,
      (SELECT free_mode_until FROM public.platform_config WHERE id = 1),
      COALESCE((SELECT pr.prof_status = 'blocked'
                  FROM public.profiles pr WHERE pr.id = p_user_id), false)
    FROM public.plans p
    WHERE p.name = 'business'
    LIMIT 1;
    RETURN;
  END IF;

  -- ► Logique normale (identique à hotfix_114).
  RETURN QUERY
  SELECT
    COALESCE(s.snap->>'name', p.name, 'none'),
    COALESCE((s.snap->>'offline_enabled')::boolean, p.offline_enabled, false),
    COALESCE((s.snap->>'max_shops')::int, p.max_shops, 0),
    COALESCE((s.snap->>'max_users_per_shop')::int, p.max_users_per_shop, 0),
    COALESCE((s.snap->>'max_products')::int, p.max_products, 0),
    COALESCE((s.snap->>'max_partner_depots_per_shop')::int,
             p.max_partner_depots_per_shop, 0),
    COALESCE((s.snap->>'max_employees_per_shop')::int,
             p.max_employees_per_shop, 0),
    COALESCE((s.snap->>'max_warehouses')::int, p.max_warehouses, 0),
    COALESCE(s.snap->'features', p.features, '[]'::jsonb),
    COALESCE(s.sub_status, 'none'),
    s.expires_at,
    (pr.prof_status = 'blocked')
  FROM public.profiles pr
  LEFT JOIN LATERAL (
    SELECT sub.sub_status, sub.expires_at, sub.plan_id,
           sub.plan_snapshot AS snap
      FROM public.subscriptions sub
     WHERE sub.user_id = p_user_id
       AND sub.sub_status IN ('active','trial')
     ORDER BY sub.expires_at DESC
     LIMIT 1
  ) s ON true
  LEFT JOIN public.plans p ON p.id = s.plan_id
  WHERE pr.id = p_user_id;
END;
$get_plan$;
GRANT EXECUTE ON FUNCTION public.get_user_plan(UUID) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Vérif (optionnel) :
-- SELECT public.sa_set_free_mode(true);         -- activer
-- SELECT public.free_mode_active();             -- doit être true
-- SELECT * FROM public.get_user_plan('<any_user_id>');  -- plan business
-- SELECT public.sa_set_free_mode(false);        -- désactiver
