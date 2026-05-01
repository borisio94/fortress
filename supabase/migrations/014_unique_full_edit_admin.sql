-- =============================================================================
-- 014 — Unicité de l'admin principal (perm `shop.full_edit`) par boutique
--
-- Contexte : la permission `shop.full_edit` (cf. enum EmployeePermission
-- côté Flutter) débloque les modifications profondes (reset, purge, etc.)
-- pour UN admin précis désigné par le propriétaire. Il ne doit y avoir
-- qu'UN SEUL admin avec cette permission par boutique (le propriétaire,
-- lui, l'a toujours implicitement via son statut owner).
--
-- Ce trigger BEFORE INSERT/UPDATE sur `shop_memberships` rejette toute
-- tentative d'attribuer `shop.full_edit` à un membre si un autre membre
-- non-owner de la même boutique l'a déjà.
--
-- Garde-fou côté SQL en complément du check Flutter dans
-- EmployeeFormSheet._submit (qui affiche un message clair à l'utilisateur).
--
-- Idempotente.
-- =============================================================================

DROP TRIGGER  IF EXISTS trg_unique_full_edit_admin ON public.shop_memberships;
DROP FUNCTION IF EXISTS public.enforce_unique_full_edit_admin() CASCADE;

CREATE OR REPLACE FUNCTION public.enforce_unique_full_edit_admin()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $enforce$
DECLARE
  v_has_full_edit BOOLEAN;
BEGIN
  -- Pas concerné si NEW.permissions ne contient pas la perm cible.
  IF NEW.permissions IS NULL THEN RETURN NEW; END IF;
  v_has_full_edit := NEW.permissions ? 'shop.full_edit';
  IF NOT v_has_full_edit THEN RETURN NEW; END IF;

  -- Owner = exempté (le owner a toujours la perm implicitement).
  IF COALESCE(NEW.is_owner, false) = true THEN RETURN NEW; END IF;

  -- Cherche un autre membership de la même boutique qui aurait déjà la perm.
  IF EXISTS (
    SELECT 1
    FROM   public.shop_memberships m
    WHERE  (m.shop_id)::text = (NEW.shop_id)::text
      AND  (m.user_id)::text <> (NEW.user_id)::text
      AND  COALESCE(m.is_owner, false) = false
      AND  m.permissions IS NOT NULL
      AND  m.permissions ? 'shop.full_edit'
  ) THEN
    RAISE EXCEPTION
      'Un autre admin de cette boutique possède déjà la permission '
      '"shop.full_edit" (admin principal). Retire-la-lui d''abord.'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END $enforce$;

CREATE TRIGGER trg_unique_full_edit_admin
BEFORE INSERT OR UPDATE OF permissions ON public.shop_memberships
FOR EACH ROW EXECUTE FUNCTION public.enforce_unique_full_edit_admin();

-- ── Vérif manuelle (à lancer après application) ────────────────────────────
-- Identifier les boutiques qui auraient PLUSIEURS admins avec shop.full_edit
-- (ne devrait pas exister grâce au trigger, mais utile au moment du backfill) :
--
--   SELECT shop_id, COUNT(*) AS nb
--   FROM   shop_memberships
--   WHERE  permissions ? 'shop.full_edit'
--     AND  COALESCE(is_owner, false) = false
--   GROUP  BY shop_id
--   HAVING COUNT(*) > 1;
--
-- Attendu : 0 ligne. Si > 0, l'admin doit retirer la perm aux doublons
-- avant que le trigger ne se déclenche sur la prochaine modification.
