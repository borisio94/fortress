-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_111_shops_quota_trigger.sql
--
-- Enforcement SERVEUR du quota de boutiques (backstop du contrôle app).
-- Trigger BEFORE INSERT sur `shops` :
--   • Super-admin (profiles.is_super_admin) → illimité.
--   • 1ère boutique TOUJOURS permise (inscription : le plan n'est parfois pas
--     encore résolu au moment du tout 1er insert).
--   • Au-delà : bloque si le nombre de boutiques du propriétaire a atteint
--     `max_shops` de son plan (lu via get_user_plan).
--
-- Idempotent.
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.enforce_shop_quota()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_is_sa BOOLEAN;
  v_max   INT;
  v_count INT;
BEGIN
  -- Pas d'owner (cas legacy/migration) → ne pas juger.
  IF NEW.owner_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- Super-admin : illimité.
  SELECT COALESCE(is_super_admin, false) INTO v_is_sa
    FROM public.profiles WHERE id = NEW.owner_id::uuid;
  IF COALESCE(v_is_sa, false) THEN
    RETURN NEW;
  END IF;

  -- Quota du plan du propriétaire.
  SELECT max_shops INTO v_max
    FROM public.get_user_plan(NEW.owner_id::uuid);
  v_max := COALESCE(v_max, 0);

  -- Boutiques déjà détenues par ce propriétaire.
  SELECT count(*) INTO v_count
    FROM public.shops WHERE owner_id = NEW.owner_id;

  -- 1ère boutique toujours permise ; au-delà → exiger le quota.
  IF v_count >= 1 AND v_count >= v_max THEN
    RAISE EXCEPTION
      'Limite de boutiques atteinte (% max) pour votre abonnement. '
      'Passez à un plan supérieur pour en créer davantage.', v_max
      USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_enforce_shop_quota ON public.shops;
CREATE TRIGGER trg_enforce_shop_quota
  BEFORE INSERT ON public.shops
  FOR EACH ROW EXECUTE FUNCTION public.enforce_shop_quota();

NOTIFY pgrst, 'reload schema';
