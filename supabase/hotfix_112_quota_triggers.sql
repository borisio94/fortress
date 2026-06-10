-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_112_quota_triggers.sql
--
-- Backstops SERVEUR des quotas (complètent l'enforcement app) :
--   • stock_locations : partenaires (max_partner_depots) & magasins
--     (max_warehouses) — totaux par propriétaire. type='shop' non limité.
--   • shop_memberships : employés (max_employees_per_shop) — par boutique,
--     hors propriétaire.
-- Quota lu via get_user_plan(owner). Super-admin → illimité.
--
-- Idempotent.
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1. Partenaires & magasins (stock_locations) ─────────────────────────────
CREATE OR REPLACE FUNCTION public.enforce_location_quota()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $loc$
DECLARE
  v_type  TEXT;
  v_is_sa BOOLEAN;
  v_max   INT;
  v_count INT;
BEGIN
  IF NEW.owner_id IS NULL THEN RETURN NEW; END IF;
  v_type := NEW.type::text;

  -- Seuls partenaires & magasins sont plafonnés (les locations type='shop'
  -- sont auto-créées avec chaque boutique → non limitées ici).
  IF v_type NOT IN ('partner', 'warehouse') THEN RETURN NEW; END IF;

  SELECT COALESCE(is_super_admin, false) INTO v_is_sa
    FROM public.profiles WHERE id = NEW.owner_id::uuid;
  IF COALESCE(v_is_sa, false) THEN RETURN NEW; END IF;

  IF v_type = 'partner' THEN
    SELECT max_partner_depots INTO v_max
      FROM public.get_user_plan(NEW.owner_id::uuid);
  ELSE
    SELECT max_warehouses INTO v_max
      FROM public.get_user_plan(NEW.owner_id::uuid);
  END IF;
  v_max := COALESCE(v_max, 0);

  SELECT count(*) INTO v_count
    FROM public.stock_locations
   WHERE owner_id = NEW.owner_id AND type::text = v_type;

  IF v_count >= v_max THEN
    IF v_type = 'partner' THEN
      RAISE EXCEPTION
        'Limite de partenaires atteinte (% max) pour votre abonnement.', v_max
        USING ERRCODE = 'P0001';
    ELSE
      RAISE EXCEPTION
        'Limite de magasins atteinte (% max) pour votre abonnement.', v_max
        USING ERRCODE = 'P0001';
    END IF;
  END IF;

  RETURN NEW;
END;
$loc$;

DROP TRIGGER IF EXISTS trg_enforce_location_quota ON public.stock_locations;
CREATE TRIGGER trg_enforce_location_quota
  BEFORE INSERT ON public.stock_locations
  FOR EACH ROW EXECUTE FUNCTION public.enforce_location_quota();

-- ── 2. Employés (shop_memberships) ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.enforce_employee_quota()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $emp$
DECLARE
  v_owner TEXT;
  v_is_sa BOOLEAN;
  v_max   INT;
  v_count INT;
BEGIN
  -- L'adhésion du propriétaire n'est pas un employé.
  IF NEW.role = 'owner' THEN RETURN NEW; END IF;

  -- Propriétaire de la boutique = porteur du plan.
  SELECT owner_id::text INTO v_owner
    FROM public.shops WHERE id::text = NEW.shop_id::text;
  IF v_owner IS NULL THEN RETURN NEW; END IF;

  SELECT COALESCE(is_super_admin, false) INTO v_is_sa
    FROM public.profiles WHERE id = v_owner::uuid;
  IF COALESCE(v_is_sa, false) THEN RETURN NEW; END IF;

  SELECT max_employees_per_shop INTO v_max
    FROM public.get_user_plan(v_owner::uuid);
  v_max := COALESCE(v_max, 0);

  -- Employés actuels (non-owner, non-archivés) de cette boutique.
  SELECT count(*) INTO v_count
    FROM public.shop_memberships
   WHERE shop_id::text = NEW.shop_id::text
     AND role <> 'owner'
     AND COALESCE(status, 'active') <> 'archived';

  IF v_count >= v_max THEN
    RAISE EXCEPTION
      'Limite d''employés atteinte (% max/boutique) pour l''abonnement. '
      'Passez à un plan supérieur.', v_max
      USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$emp$;

DROP TRIGGER IF EXISTS trg_enforce_employee_quota ON public.shop_memberships;
CREATE TRIGGER trg_enforce_employee_quota
  BEFORE INSERT ON public.shop_memberships
  FOR EACH ROW EXECUTE FUNCTION public.enforce_employee_quota();

NOTIFY pgrst, 'reload schema';
