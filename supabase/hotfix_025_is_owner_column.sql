-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_025_is_owner_column.sql
--
-- 1. Ajoute la colonne `is_owner BOOLEAN DEFAULT false` sur shop_memberships.
-- 2. Backfill : is_owner = true pour toute ligne où role='owner'.
-- 3. Trigger d'auto-sync : NEW.is_owner = (NEW.role = 'owner').
--    → Garantit que is_owner reste cohérent avec role à chaque INSERT/UPDATE.
-- 4. Trigger d'immutabilité :
--    - UPDATE bloqué si on tente de retirer is_owner ou changer le role d'un
--      owner (le propriétaire est intouchable).
--    - DELETE bloqué tant que la boutique existe (cascade de shops OK).
-- 5. Index unique partiel : un seul is_owner=true par boutique.
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1. Colonne is_owner ──────────────────────────────────────────────────
ALTER TABLE shop_memberships
  ADD COLUMN IF NOT EXISTS is_owner BOOLEAN DEFAULT false;

-- ── 2. Backfill : is_owner=true pour les owners existants ────────────────
UPDATE shop_memberships
   SET is_owner = true
 WHERE role = 'owner'
   AND is_owner = false;

-- Sécurité : aucune ligne is_owner=true ne doit avoir un role différent
-- (anomalie historique avant ce hotfix).
UPDATE shop_memberships
   SET is_owner = false
 WHERE role <> 'owner'
   AND is_owner = true;

-- ── 3. Index unique partiel : un seul owner par boutique ──────────────────
DROP INDEX IF EXISTS idx_shop_memberships_unique_owner;
CREATE UNIQUE INDEX idx_shop_memberships_unique_owner
  ON shop_memberships (shop_id)
  WHERE is_owner = true;

-- ── 4. Trigger : auto-sync is_owner avec role + immutabilité ─────────────
DROP TRIGGER  IF EXISTS trg_enforce_is_owner ON shop_memberships;
DROP FUNCTION IF EXISTS public.enforce_is_owner() CASCADE;

CREATE OR REPLACE FUNCTION public.enforce_is_owner()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $enforce$
BEGIN
  -- Auto-sync : la colonne is_owner est dérivée du role.
  NEW.is_owner := (NEW.role = 'owner');

  -- Immutabilité d'un owner existant
  IF TG_OP = 'UPDATE' AND OLD.is_owner = true THEN
    -- Bloquer toute tentative de "déposséder" le propriétaire
    IF NEW.role <> 'owner' THEN
      RAISE EXCEPTION 'Le propriétaire d''une boutique ne peut pas changer '
                      'de rôle. Transférez la propriété via shops.owner_id '
                      'puis recréez la membership.'
        USING ERRCODE = '42501';
    END IF;
    -- Bloquer le changement de user_id ou shop_id
    IF NEW.user_id::text <> OLD.user_id::text
       OR NEW.shop_id::text <> OLD.shop_id::text THEN
      RAISE EXCEPTION 'shop_id et user_id sont immuables pour un propriétaire'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  RETURN NEW;
END;
$enforce$;

CREATE TRIGGER trg_enforce_is_owner
BEFORE INSERT OR UPDATE ON shop_memberships
FOR EACH ROW EXECUTE FUNCTION public.enforce_is_owner();

-- ── 5. Trigger DELETE : protéger le owner sauf cascade shops ─────────────
DROP TRIGGER  IF EXISTS trg_protect_owner_delete ON shop_memberships;
DROP FUNCTION IF EXISTS public.protect_owner_delete() CASCADE;

CREATE OR REPLACE FUNCTION public.protect_owner_delete()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $protect$
BEGIN
  -- Si la ligne supprimée est celle du owner ET que la boutique existe
  -- toujours → on bloque. Si la boutique n'existe plus, c'est une cascade
  -- légitime (DELETE shops → CASCADE memberships) : on laisse passer.
  IF OLD.is_owner = true THEN
    IF EXISTS (SELECT 1 FROM shops WHERE id::text = OLD.shop_id::text) THEN
      RAISE EXCEPTION 'Impossible de retirer le propriétaire de la boutique. '
                      'Supprimez d''abord la boutique elle-même.'
        USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN OLD;
END;
$protect$;

CREATE TRIGGER trg_protect_owner_delete
BEFORE DELETE ON shop_memberships
FOR EACH ROW EXECUTE FUNCTION public.protect_owner_delete();

-- ── 6. Sanity checks (à lancer après) ────────────────────────────────────
-- SELECT shop_id, COUNT(*) FILTER (WHERE is_owner) AS owners
--   FROM shop_memberships GROUP BY shop_id HAVING COUNT(*) FILTER (WHERE is_owner) <> 1;
--   → attendu : 0 ligne (chaque boutique a exactement 1 owner)
--
-- SELECT role, is_owner, COUNT(*) FROM shop_memberships GROUP BY role, is_owner;
--   → attendu : (owner, true) + (admin, false) + (user, false). Aucun (owner, false) ni (admin, true).
