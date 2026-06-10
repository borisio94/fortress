-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_114_plan_snapshot.sql
--
-- « Modification d'un plan applicable au prochain cycle » :
-- On FIGE (snapshot) les conditions du plan (quotas + features + offline) sur
-- l'abonnement au moment du paiement. get_user_plan lit ce snapshot. Éditer un
-- plan n'affecte donc plus les abonnés en cours — les nouvelles conditions ne
-- s'appliquent qu'au prochain renouvellement (nouvel abonnement OU changement
-- de plan_id). Le PRIX était déjà figé par paiement (amount_paid).
--
-- Transparent pour l'app : get_user_plan renvoie les mêmes colonnes.
-- Idempotent.
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. Colonne snapshot ─────────────────────────────────────────────────────
ALTER TABLE public.subscriptions
  ADD COLUMN IF NOT EXISTS plan_snapshot JSONB;

-- ── 2. Trigger : fige le plan sur l'abonnement (INSERT + changement plan_id) ─
CREATE OR REPLACE FUNCTION public.snapshot_plan_on_subscription()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $snap$
BEGIN
  IF (TG_OP = 'INSERT'
        AND NEW.plan_snapshot IS NULL AND NEW.plan_id IS NOT NULL)
     OR (TG_OP = 'UPDATE'
        AND NEW.plan_id IS DISTINCT FROM OLD.plan_id) THEN
    SELECT jsonb_build_object(
      'name',                        name,
      'label',                       label,
      'offline_enabled',             offline_enabled,
      'max_shops',                   max_shops,
      'max_users_per_shop',          max_users_per_shop,
      'max_products',                max_products,
      'max_partner_depots_per_shop', max_partner_depots_per_shop,
      'max_employees_per_shop',      max_employees_per_shop,
      'max_warehouses',              max_warehouses,
      'features',                    COALESCE(features, '[]'::jsonb)
    ) INTO NEW.plan_snapshot
    FROM public.plans WHERE id = NEW.plan_id;
  END IF;
  RETURN NEW;
END;
$snap$;

DROP TRIGGER IF EXISTS trg_snapshot_plan ON public.subscriptions;
CREATE TRIGGER trg_snapshot_plan
  BEFORE INSERT OR UPDATE OF plan_id ON public.subscriptions
  FOR EACH ROW EXECUTE FUNCTION public.snapshot_plan_on_subscription();

-- ── 3. Backfill des abonnements courants (les fige dès maintenant) ──────────
UPDATE public.subscriptions s SET plan_snapshot = jsonb_build_object(
    'name',                        p.name,
    'label',                       p.label,
    'offline_enabled',             p.offline_enabled,
    'max_shops',                   p.max_shops,
    'max_users_per_shop',          p.max_users_per_shop,
    'max_products',                p.max_products,
    'max_partner_depots_per_shop', p.max_partner_depots_per_shop,
    'max_employees_per_shop',      p.max_employees_per_shop,
    'max_warehouses',              p.max_warehouses,
    'features',                    COALESCE(p.features, '[]'::jsonb))
  FROM public.plans p
 WHERE s.plan_id = p.id
   AND s.plan_snapshot IS NULL
   AND s.sub_status IN ('active','trial');

COMMIT;

-- ── 4. get_user_plan : lit le snapshot (fallback plan live si null) ─────────
DROP FUNCTION IF EXISTS public.get_user_plan(UUID);
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
