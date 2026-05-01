-- ═══════════════════════════════════════════════════════════════════════════
-- Fortress — Migration 007 : RPC de purge des logs d'activité
--
-- Deux fonctions, chacune avec son contrôle d'accès :
--   * purge_shop_activity_logs(p_shop_id)  → admin/propriétaire de la boutique
--                                             ou super admin
--   * purge_all_activity_logs()            → super admin uniquement
--
-- Retournent le nombre de lignes supprimées. Insèrent un log "logs_purged"
-- après la purge pour tracer l'action (même sur sa propre trace) — le log
-- purgé n'inclut PAS cette nouvelle ligne, donc elle survit.
-- ═══════════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS purge_shop_activity_logs(UUID);
CREATE FUNCTION purge_shop_activity_logs(p_shop_id UUID)
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER
SET row_security = off
AS $fn$
DECLARE
  v_owner    UUID;
  v_is_sa    BOOLEAN;
  v_is_admin BOOLEAN;
  v_name     TEXT;
  v_count    INT;
BEGIN
  SELECT COALESCE(is_super_admin, false) INTO v_is_sa
    FROM profiles WHERE id = auth.uid();

  SELECT owner_id, name INTO v_owner, v_name
    FROM shops WHERE id::text = p_shop_id::text;

  SELECT EXISTS(
    SELECT 1 FROM shop_memberships
     WHERE shop_id::text = p_shop_id::text
       AND user_id::text = (auth.uid())::text
       AND role = 'admin'
  ) INTO v_is_admin;

  IF NOT v_is_sa
     AND v_owner IS DISTINCT FROM auth.uid()
     AND NOT v_is_admin
  THEN
    RAISE EXCEPTION 'Non autorisé : propriétaire, admin boutique ou super admin requis';
  END IF;

  WITH deleted AS (
    DELETE FROM activity_logs
     WHERE shop_id::text = p_shop_id::text
     RETURNING 1
  )
  SELECT count(*) INTO v_count FROM deleted;

  INSERT INTO activity_logs (actor_id, actor_email, action, target_type,
                             target_id, target_label, shop_id, details)
  VALUES (auth.uid(),
          (SELECT email FROM auth.users WHERE id = auth.uid()),
          'logs_purged', 'shop', p_shop_id::text, v_name, p_shop_id,
          jsonb_build_object('count', v_count, 'scope', 'shop'));

  RETURN v_count;
END $fn$;
REVOKE ALL ON FUNCTION purge_shop_activity_logs(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION purge_shop_activity_logs(UUID) TO authenticated;

-- @@CHUNK@@

DROP FUNCTION IF EXISTS purge_all_activity_logs();
CREATE FUNCTION purge_all_activity_logs()
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER
SET row_security = off
AS $fn$
DECLARE
  v_count INT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles
                  WHERE id = auth.uid() AND is_super_admin = true)
  THEN
    RAISE EXCEPTION 'Seul un super admin peut purger tous les logs';
  END IF;

  WITH deleted AS (
    DELETE FROM activity_logs WHERE true RETURNING 1
  )
  SELECT count(*) INTO v_count FROM deleted;

  INSERT INTO activity_logs (actor_id, actor_email, action, target_type,
                             details)
  VALUES (auth.uid(),
          (SELECT email FROM auth.users WHERE id = auth.uid()),
          'logs_purged', 'platform',
          jsonb_build_object('count', v_count, 'scope', 'platform'));

  RETURN v_count;
END $fn$;
REVOKE ALL ON FUNCTION purge_all_activity_logs() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION purge_all_activity_logs() TO authenticated;
