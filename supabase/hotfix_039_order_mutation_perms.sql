-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_039_order_mutation_perms.sql
--
-- Défense en profondeur côté SQL pour les mutations sur `orders` :
--   1. INSERT ou UPDATE qui pose `status` à 'cancelled' / 'refunded' →
--      requiert la permission `sales.cancel`.
--   2. INSERT avec discount_amount > 0, OU UPDATE qui modifie
--      `discount_amount` → requiert la permission `sales.discount`.
--
-- Les gates UI (caisse_page.dart, cart_widget.dart) gèrent déjà ces deux
-- cas côté client. Ce hotfix ferme la porte aux appels REST/RPC directs
-- qui contournent l'UI.
--
-- Permission resolution : owner du shop OR super_admin global → bypass
-- complet ; sinon on lit shop_memberships.permissions (JSONB) avec deny
-- prioritaire, puis fallback sur les défauts du rôle (admin = toutes les
-- perms sauf owner-only ; user = 4 perms de base).
--
-- 100 % idempotent.
-- ════════════════════════════════════════════════════════════════════════════


-- ── Helper : auth.uid() a-t-il la permission `p_perm` dans le shop ? ──────
DROP FUNCTION IF EXISTS public._user_has_permission(TEXT, TEXT);
CREATE FUNCTION public._user_has_permission(p_shop_id TEXT, p_perm TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $hp$
DECLARE
  v_uid   TEXT := auth.uid()::text;
  v_role  TEXT;
  v_perms JSONB;
BEGIN
  -- service_role / connexion sans JWT → on laisse passer (déjà en
  -- by-pass RLS de toute façon, ce trigger ne doit pas bloquer une
  -- maintenance serveur).
  IF v_uid IS NULL THEN RETURN TRUE; END IF;

  -- Owner du shop → tous les droits.
  IF EXISTS (
    SELECT 1 FROM shops
     WHERE id::text       = p_shop_id
       AND owner_id::text = v_uid
  ) THEN RETURN TRUE; END IF;

  -- Super admin global → tous les droits.
  IF EXISTS (
    SELECT 1 FROM profiles
     WHERE id::text = v_uid
       AND COALESCE(is_super_admin, false) = TRUE
  ) THEN RETURN TRUE; END IF;

  -- Lire la membership de l'appelant pour ce shop.
  SELECT role, COALESCE(permissions, '[]'::jsonb)
    INTO v_role, v_perms
    FROM shop_memberships
   WHERE shop_id::text = p_shop_id
     AND user_id::text = v_uid
   LIMIT 1;

  IF v_role IS NULL THEN RETURN FALSE; END IF;

  -- Deny explicite gagne (cf. format JSONB MemberPermissions.toList).
  IF v_perms ? ('deny:' || p_perm) THEN RETURN FALSE; END IF;
  -- Grant explicite.
  IF v_perms ? p_perm THEN RETURN TRUE; END IF;

  -- Fallback rôle (mirroir de defaultPermissionsForRole côté Dart).
  IF v_role = 'owner' THEN RETURN TRUE; END IF;
  IF v_role = 'admin' AND p_perm NOT IN ('shop.delete', 'admin.remove') THEN
    RETURN TRUE;
  END IF;
  IF v_role = 'user' AND p_perm IN
       ('inventory.view', 'caisse.access', 'caisse.sell', 'crm.view') THEN
    RETURN TRUE;
  END IF;

  RETURN FALSE;
END;
$hp$;

ALTER FUNCTION public._user_has_permission(TEXT, TEXT) OWNER TO postgres;
REVOKE ALL ON FUNCTION public._user_has_permission(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public._user_has_permission(TEXT, TEXT) TO authenticated;


-- ── Trigger : INSERT/UPDATE sur orders ────────────────────────────────────
DROP TRIGGER  IF EXISTS trg_enforce_order_mutation_perms ON orders;
DROP FUNCTION IF EXISTS public.enforce_order_mutation_perms() CASCADE;

CREATE OR REPLACE FUNCTION public.enforce_order_mutation_perms()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $enforce$
BEGIN
  -- ── 1. Statut cancelled / refunded ─────────────────────────────────────
  -- INSERT direct avec ce statut OU UPDATE qui y transitionne.
  IF NEW.status IN ('cancelled', 'refunded')
     AND (TG_OP = 'INSERT'
          OR (TG_OP = 'UPDATE'
              AND COALESCE(OLD.status, '') <> NEW.status)) THEN
    IF NOT public._user_has_permission(NEW.shop_id::text, 'sales.cancel') THEN
      RAISE EXCEPTION
        'Action interdite : annulation ou remboursement requiert '
        'la permission sales.cancel'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  -- ── 2. Modification de la remise globale ──────────────────────────────
  -- INSERT avec une remise > 0 OU UPDATE qui modifie discount_amount.
  IF (TG_OP = 'INSERT' AND COALESCE(NEW.discount_amount, 0) > 0)
     OR (TG_OP = 'UPDATE'
         AND COALESCE(NEW.discount_amount, 0)
                 <> COALESCE(OLD.discount_amount, 0)) THEN
    IF NOT public._user_has_permission(NEW.shop_id::text, 'sales.discount') THEN
      RAISE EXCEPTION
        'Action interdite : modification de la remise requiert '
        'la permission sales.discount'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  RETURN NEW;
END;
$enforce$;

CREATE TRIGGER trg_enforce_order_mutation_perms
BEFORE INSERT OR UPDATE ON orders
FOR EACH ROW EXECUTE FUNCTION public.enforce_order_mutation_perms();


-- ── Vérifications après application (à lancer manuellement) ─────────────
-- SELECT tgname FROM pg_trigger WHERE tgname = 'trg_enforce_order_mutation_perms';
-- → attendu : 1 ligne
--
-- -- Smoke test : un user sans sales.cancel ne peut plus annuler
-- -- (à exécuter avec une session JWT d'un caissier role='user') :
-- -- UPDATE orders SET status='cancelled' WHERE id='...';
-- -- → attendu : ERROR 42501 "annulation ou remboursement requiert ..."
