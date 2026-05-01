-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_024_roles_permissions.sql
--
-- Refonte du modèle de rôles : owner | admin | user (canon).
--
-- 1. Migration des rôles existants vers le canon (manager→admin,
--    cashier/employee→user)
-- 2. Migration du propriétaire : sa ligne shop_memberships passe en 'owner'.
--    Si elle n'existe pas (cas d'une boutique créée avant hotfix_018), on
--    l'insère.
-- 3. CHECK constraint resserré : role IN ('owner','admin','user') uniquement.
-- 4. 5 nouvelles permissions ajoutées :
--      sales.cancel, sales.discount, members.invite, shop.delete, admin.remove
--    - owner reçoit les 5
--    - admin reçoit 3 (sales.cancel, sales.discount, members.invite)
--    - shop.delete et admin.remove restent réservées au owner
-- 5. Trigger enforce_max_admins : max 3 admins par boutique (owner inclus).
-- 6. _is_shop_admin reconnaît explicitement role='owner' (en plus de
--    shops.owner_id et profiles.is_super_admin).
--
-- Les RLS existantes (hotfix_018) restent valides car elles s'appuient sur
-- _is_shop_admin qui couvre owner/admin/super-admin.
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1. Mapping des rôles legacy vers le canon ─────────────────────────────
UPDATE shop_memberships SET role = 'admin' WHERE role = 'manager';
UPDATE shop_memberships SET role = 'user'  WHERE role IN ('cashier','employee');

-- ── 2. Migration du propriétaire : role='owner' ──────────────────────────
-- Pour chaque shop, la ligne shop_memberships du propriétaire passe à 'owner'.
UPDATE shop_memberships sm
   SET role = 'owner'
  FROM shops s
 WHERE s.id::text       = sm.shop_id::text
   AND sm.user_id::text = s.owner_id::text;

-- Si le propriétaire n'a pas encore de ligne shop_memberships (boutique
-- créée avant hotfix_018), on l'insère avec role='owner' et permissions
-- vides — la mise à jour finale en étape 4 lui ajoutera tout.
INSERT INTO shop_memberships
    (shop_id, user_id, role, permissions, status, created_at)
SELECT s.id::text, s.owner_id::text, 'owner', '[]'::jsonb, 'active', now()
  FROM shops s
 WHERE s.owner_id IS NOT NULL
   AND NOT EXISTS (
     SELECT 1 FROM shop_memberships sm
      WHERE sm.shop_id::text  = s.id::text
        AND sm.user_id::text  = s.owner_id::text
   );

-- ── 3. CHECK constraint canonique ─────────────────────────────────────────
DO $drop_role_chk$
DECLARE v_conname text;
BEGIN
  FOR v_conname IN
    SELECT conname FROM pg_constraint
     WHERE conrelid = 'shop_memberships'::regclass
       AND contype  = 'c'
       AND pg_get_constraintdef(oid) ILIKE '%role%'
       AND conname  <> 'shop_memberships_status_chk'
  LOOP
    EXECUTE format('ALTER TABLE shop_memberships DROP CONSTRAINT %I',
        v_conname);
  END LOOP;
END $drop_role_chk$;

ALTER TABLE shop_memberships
  ADD CONSTRAINT shop_memberships_role_chk
  CHECK (role IN ('owner','admin','user'));

-- ── 4. Backfill des 5 nouvelles permissions ──────────────────────────────
-- Owner : reçoit les 5 (full pouvoir).
UPDATE shop_memberships
   SET permissions = (
     SELECT COALESCE(jsonb_agg(DISTINCT v), '[]'::jsonb) FROM (
       SELECT jsonb_array_elements_text(
                COALESCE(permissions, '[]'::jsonb)) AS v
       UNION
       SELECT unnest(ARRAY[
         'sales.cancel','sales.discount','members.invite',
         'shop.delete','admin.remove'
       ]) AS v
     ) t
   )
 WHERE role = 'owner';

-- Admin : reçoit 3 sur 5. shop.delete et admin.remove restent owner-only
-- pour empêcher un admin de détruire la boutique ou retirer son patron.
UPDATE shop_memberships
   SET permissions = (
     SELECT COALESCE(jsonb_agg(DISTINCT v), '[]'::jsonb) FROM (
       SELECT jsonb_array_elements_text(
                COALESCE(permissions, '[]'::jsonb)) AS v
       UNION
       SELECT unnest(ARRAY[
         'sales.cancel','sales.discount','members.invite'
       ]) AS v
     ) t
   )
 WHERE role = 'admin';

-- ── 5. Trigger enforce_max_admins ────────────────────────────────────────
-- Bloque toute création / promotion qui ferait passer le nombre de
-- (owner+admin) actifs au-delà de 3 dans une boutique.
DROP TRIGGER  IF EXISTS trg_enforce_max_admins ON shop_memberships;
DROP FUNCTION IF EXISTS public.enforce_max_admins() CASCADE;

CREATE OR REPLACE FUNCTION public.enforce_max_admins()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $enforce$
DECLARE
  v_count INT;
BEGIN
  IF NEW.role IN ('owner','admin') THEN
    SELECT COUNT(*) INTO v_count
      FROM shop_memberships
     WHERE shop_id::text = NEW.shop_id::text
       AND role IN ('owner','admin')
       AND COALESCE(status, 'active') = 'active'
       AND (
         TG_OP = 'INSERT'
         OR NOT (shop_id::text = OLD.shop_id::text
                 AND user_id::text = OLD.user_id::text)
       );
    IF v_count >= 3 THEN
      RAISE EXCEPTION 'Maximum 3 administrateurs par boutique '
                      '(propriétaire inclus)'
        USING ERRCODE = '23514';
    END IF;
  END IF;
  RETURN NEW;
END;
$enforce$;

CREATE TRIGGER trg_enforce_max_admins
BEFORE INSERT OR UPDATE OF role ON shop_memberships
FOR EACH ROW EXECUTE FUNCTION public.enforce_max_admins();

-- ── 6. _is_shop_admin reconnaît explicitement role='owner' ───────────────
-- ⚠ Pas de DROP FUNCTION : les policies RLS shop_memberships_{select,write}
--   dépendent de cette fonction. Comme la signature reste identique
--   (TEXT → BOOLEAN), CREATE OR REPLACE seul suffit.
CREATE OR REPLACE FUNCTION public._is_shop_admin(p_shop_id TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $is_adm$
BEGIN
  RETURN
    EXISTS (
      SELECT 1 FROM shops
       WHERE id::text       = p_shop_id
         AND owner_id::text = auth.uid()::text
    )
    OR EXISTS (
      SELECT 1 FROM shop_memberships
       WHERE shop_id::text = p_shop_id
         AND user_id::text = auth.uid()::text
         AND role IN ('owner','admin')
         AND COALESCE(status, 'active') = 'active'
    )
    OR EXISTS (
      SELECT 1 FROM profiles
       WHERE id::text          = auth.uid()::text
         AND is_super_admin    = true
    );
END;
$is_adm$;

GRANT EXECUTE ON FUNCTION public._is_shop_admin(TEXT) TO authenticated;

-- ── 7. Sanity check (lecture seule) ───────────────────────────────────────
-- Tu peux lancer ces SELECT pour vérifier après run :
--
-- SELECT role, COUNT(*) FROM shop_memberships GROUP BY role;
--   → attendu : owner=N, admin=M, user=P (rien d'autre)
--
-- SELECT s.id, s.name,
--        COUNT(*) FILTER (WHERE sm.role IN ('owner','admin')) AS admins
--   FROM shops s
--   LEFT JOIN shop_memberships sm ON sm.shop_id::text = s.id::text
--   GROUP BY s.id, s.name
--   ORDER BY admins DESC;
--   → max 3 attendu pour les nouvelles boutiques (existantes peuvent
--     dépasser, le trigger ne fait que prévenir les futurs INSERT/UPDATE)
