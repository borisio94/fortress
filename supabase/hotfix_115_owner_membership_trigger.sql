-- =============================================================================
-- hotfix_115_owner_membership_trigger.sql
--
-- Bug : à la création d'une boutique (surtout via le tunnel d'inscription
-- signUp → auto-login → createShop), l'INSERT applicatif de la membership
-- « owner » échouait par moments avec « new row violates row-level security
-- policy for table shop_memberships » (42501). La création de cette première
-- membership dépend du contexte RLS/session juste après le sign-up, ce qui est
-- fragile.
--
-- Fix : un trigger AFTER INSERT sur `shops` crée la membership owner
-- automatiquement, en `SECURITY DEFINER` (donc SANS passer par la RLS ni
-- dépendre de auth.uid() au moment T). L'invariant « toute boutique a une
-- membership owner » est désormais garanti côté serveur. Le code Flutter
-- n'insère plus la membership lui-même (cf. AppDatabase.createShop).
--
-- Idempotente. Garde NOT EXISTS → coexiste sans risque avec d'anciennes
-- données / un éventuel insert applicatif résiduel.
-- =============================================================================

CREATE OR REPLACE FUNCTION public._create_owner_membership()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- Boutique sans propriétaire (cas improbable) → rien à faire.
  IF NEW.owner_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- Évite tout doublon (le trigger enforce_is_owner posera is_owner=true ;
  -- l'index unique partiel impose un seul owner par boutique).
  IF NOT EXISTS (
    SELECT 1 FROM public.shop_memberships
     WHERE shop_id::text = NEW.id::text
       AND user_id::text = NEW.owner_id::text
  ) THEN
    INSERT INTO public.shop_memberships (shop_id, user_id, role)
    VALUES (NEW.id, NEW.owner_id, 'owner');
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_create_owner_membership ON public.shops;
CREATE TRIGGER trg_create_owner_membership
AFTER INSERT ON public.shops
FOR EACH ROW EXECUTE FUNCTION public._create_owner_membership();

-- Recharger le cache de schéma PostgREST
NOTIFY pgrst, 'reload schema';
