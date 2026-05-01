-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_037_reenforce_max_admins.sql
--
-- Re-applique le trigger `trg_enforce_max_admins` défini initialement dans
-- hotfix_024 — utile si ce hotfix n'a pas été exécuté sur l'instance ou si
-- le trigger a été détruit accidentellement (ex: cascade DROP FUNCTION).
--
-- Symptôme observé : un admin parvient à promouvoir 4+ employés au rôle
-- 'admin' alors que la limite est de 3 administrateurs par boutique
-- (propriétaire inclus). Cause : trigger absent côté Postgres.
--
-- 100 % idempotent : peut être appliqué N fois sans effet de bord.
-- ════════════════════════════════════════════════════════════════════════════

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
  -- N'agit que si la nouvelle ligne est owner ou admin (les rétrogradations
  -- vers 'user' sont toujours autorisées).
  IF NEW.role IN ('owner','admin') THEN
    SELECT COUNT(*) INTO v_count
      FROM shop_memberships
     WHERE shop_id::text = NEW.shop_id::text
       AND role IN ('owner','admin')
       AND COALESCE(status, 'active') = 'active'
       AND (
         -- Sur INSERT : on compte tout.
         -- Sur UPDATE : on exclut la ligne en cours d'édition (sinon une
         -- self-update d'un admin qui reste admin se compterait deux fois
         -- et bloquerait à tort).
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

-- ── Vérification (à lancer manuellement) ─────────────────────────────────
-- SELECT shop_id,
--        COUNT(*) FILTER (WHERE role IN ('owner','admin')
--                          AND COALESCE(status,'active') = 'active') AS admins
--   FROM shop_memberships
--  GROUP BY shop_id
--  HAVING COUNT(*) FILTER (WHERE role IN ('owner','admin')
--                           AND COALESCE(status,'active') = 'active') > 3;
-- → attendu : 0 ligne. Si une ligne sort, la boutique avait déjà été
--   peuplée au-dessus de la limite avant l'application du trigger ;
--   il faut alors rétrograder manuellement le surplus avant que le
--   trigger ne devienne efficace pour les futurs UPDATE.
