-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_109_member_suspension.sql
--
-- Suspension d'un MEMBRE (employé) d'une boutique :
--   - réutilise set_employee_status (hotfix_018) qui pose shop_memberships.status
--   - l'ouvre AUSSI au super-admin (avant : admin/owner de la boutique seulement)
--   - interdit de cibler le PROPRIÉTAIRE (sa suspension = suspension de la
--     boutique, via suspend_shop) et de se cibler soi-même.
--
-- L'enforcement (un membre suspendu ne peut plus accéder à la boutique) est
-- côté app (ShopShell + getMembershipStatus). status='suspended' suffit.
--
-- Idempotent.
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.set_employee_status(
  p_shop_id TEXT,
  p_user_id TEXT,
  p_status  TEXT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $set_st$
BEGIN
  -- Admin/owner de la boutique OU super-admin.
  IF NOT (public._is_shop_admin(p_shop_id) OR public._is_super_admin()) THEN
    RAISE EXCEPTION 'Réservé aux administrateurs de la boutique'
      USING ERRCODE = '42501';
  END IF;
  IF p_status NOT IN ('active','suspended','archived') THEN
    RAISE EXCEPTION 'Statut invalide' USING ERRCODE = '22023';
  END IF;
  -- Le propriétaire ne se gère pas ici (suspendre la boutique à la place).
  IF EXISTS (SELECT 1 FROM shops
              WHERE id::text = p_shop_id AND owner_id::text = p_user_id) THEN
    RAISE EXCEPTION 'Le propriétaire ne peut pas être suspendu ici '
                    '(suspendre la boutique à la place)'
      USING ERRCODE = 'P0001';
  END IF;
  -- Pas d'auto-suspension.
  IF p_user_id = auth.uid()::text THEN
    RAISE EXCEPTION 'Action impossible sur votre propre compte'
      USING ERRCODE = 'P0001';
  END IF;

  UPDATE shop_memberships
     SET status = p_status
   WHERE shop_id::text = p_shop_id AND user_id::text = p_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Employé introuvable dans cette boutique'
      USING ERRCODE = 'P0002';
  END IF;
END;
$set_st$;

GRANT EXECUTE ON FUNCTION public.set_employee_status(TEXT, TEXT, TEXT)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
