-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_060_history_archive.sql
--
-- Ajoute la possibilité d'**archiver** ou **supprimer** des entrées de
-- `activity_logs`, réservée au super-admin OU au propriétaire de la
-- boutique concernée. Toute tentative non autorisée est elle-même loggée
-- (audit de l'audit) — interdit aux tiers de masquer leurs traces.
--
-- Schéma :
--   * Nouvelles colonnes `is_archived`, `archived_by`, `archived_at`,
--     `archive_reason` sur `activity_logs` (idempotent via IF NOT EXISTS).
--
-- RPCs SECURITY DEFINER (auth.uid() reste lisible) :
--   * `archive_activity_logs(p_log_ids TEXT[], p_reason TEXT)`
--   * `delete_activity_logs(p_log_ids TEXT[], p_reason TEXT)`
--
-- Règle de permission :
--   - Super-admin → autorisé sur tous les logs.
--   - Propriétaire d'une boutique → autorisé uniquement sur les logs dont
--     `shop_id` correspond à une de ses boutiques.
--   - Autres rôles (admin shop, employé) → refusés + log de tentative.
-- ════════════════════════════════════════════════════════════════════════════

-- 1. Schéma : colonnes d'archivage --------------------------------------------

ALTER TABLE public.activity_logs
  ADD COLUMN IF NOT EXISTS is_archived    BOOLEAN     DEFAULT false NOT NULL;
ALTER TABLE public.activity_logs
  ADD COLUMN IF NOT EXISTS archived_by    UUID;
ALTER TABLE public.activity_logs
  ADD COLUMN IF NOT EXISTS archived_at    TIMESTAMPTZ;
ALTER TABLE public.activity_logs
  ADD COLUMN IF NOT EXISTS archive_reason TEXT;

CREATE INDEX IF NOT EXISTS activity_logs_archived_idx
  ON public.activity_logs(is_archived) WHERE is_archived = true;

COMMENT ON COLUMN public.activity_logs.is_archived IS
  'Marqué TRUE quand le log a été archivé via archive_activity_logs RPC. '
  'Filtre par défaut côté UI mais reste consultable.';
COMMENT ON COLUMN public.activity_logs.archived_by IS
  'auth.uid() du super-admin ou owner ayant archivé.';

-- 2. Helper : autorisation d'agir sur un set de logs --------------------------
--    Retourne TRUE si l'appelant est super-admin OU est owner de TOUTES les
--    boutiques rattachées aux logs visés. Toute exception (ex: log sans
--    shop_id pour un non super-admin) → FALSE.

CREATE OR REPLACE FUNCTION public._can_manage_activity_logs(p_log_ids TEXT[])
RETURNS BOOLEAN
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $can$
DECLARE
  v_is_sa     BOOLEAN;
  v_uid_t     TEXT := auth.uid()::text;
  v_unown_cnt INT;
BEGIN
  IF v_uid_t IS NULL OR v_uid_t = '' THEN RETURN FALSE; END IF;

  SELECT COALESCE(is_super_admin, false) INTO v_is_sa
    FROM profiles WHERE id::text = v_uid_t;
  IF v_is_sa THEN RETURN TRUE; END IF;

  -- Pour un non-SA : tous les logs visés doivent appartenir à une de ses
  -- boutiques. On compte combien sortent de ce périmètre — 0 = OK.
  SELECT COUNT(*) INTO v_unown_cnt
    FROM activity_logs l
   WHERE l.id::text = ANY(p_log_ids)
     AND (
       l.shop_id IS NULL
       OR NOT EXISTS (
         SELECT 1 FROM shops s
          WHERE s.id::text = l.shop_id::text
            AND s.owner_id::text = v_uid_t
       )
     );

  RETURN v_unown_cnt = 0;
END $can$;

-- 3. RPC archive_activity_logs ------------------------------------------------

DROP FUNCTION IF EXISTS public.archive_activity_logs(TEXT[], TEXT);
CREATE FUNCTION public.archive_activity_logs(
  p_log_ids TEXT[],
  p_reason  TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $arch$
DECLARE
  v_uid     UUID := auth.uid();
  v_email   TEXT;
  v_count   INT;
BEGIN
  IF p_log_ids IS NULL OR array_length(p_log_ids, 1) IS NULL THEN
    RETURN jsonb_build_object('archived', 0);
  END IF;

  SELECT email INTO v_email
    FROM auth.users WHERE id = v_uid;

  IF NOT public._can_manage_activity_logs(p_log_ids) THEN
    -- Audit de l'audit : on log la tentative refusée, puis on lève.
    INSERT INTO activity_logs (
      actor_id, actor_email, action, target_type,
      target_id, target_label, details
    ) VALUES (
      v_uid, v_email,
      'activity_logs_archive_attempt_unauthorized',
      'activity_log', NULL, 'attempted',
      jsonb_build_object(
        'log_ids',  p_log_ids,
        'reason',   p_reason,
        'count',    array_length(p_log_ids, 1)
      )
    );
    RAISE EXCEPTION 'Non autorisé : super-admin ou propriétaire requis pour archiver ces logs';
  END IF;

  UPDATE activity_logs
     SET is_archived    = true,
         archived_by    = v_uid,
         archived_at    = now(),
         archive_reason = p_reason
   WHERE id::text = ANY(p_log_ids)
     AND (is_archived IS NULL OR is_archived = false);
  GET DIAGNOSTICS v_count = ROW_COUNT;

  -- Audit succès
  INSERT INTO activity_logs (
    actor_id, actor_email, action, target_type,
    target_id, target_label, details
  ) VALUES (
    v_uid, v_email, 'activity_logs_archived',
    'activity_log', NULL, 'archived',
    jsonb_build_object(
      'archived', v_count,
      'reason',   p_reason,
      'log_ids',  p_log_ids
    )
  );

  RETURN jsonb_build_object('archived', v_count);
END $arch$;

REVOKE ALL ON FUNCTION public.archive_activity_logs(TEXT[], TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.archive_activity_logs(TEXT[], TEXT) TO authenticated;

-- 4. RPC delete_activity_logs ------------------------------------------------

DROP FUNCTION IF EXISTS public.delete_activity_logs(TEXT[], TEXT);
CREATE FUNCTION public.delete_activity_logs(
  p_log_ids TEXT[],
  p_reason  TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $del$
DECLARE
  v_uid     UUID := auth.uid();
  v_email   TEXT;
  v_count   INT;
BEGIN
  IF p_log_ids IS NULL OR array_length(p_log_ids, 1) IS NULL THEN
    RETURN jsonb_build_object('deleted', 0);
  END IF;

  SELECT email INTO v_email
    FROM auth.users WHERE id = v_uid;

  IF NOT public._can_manage_activity_logs(p_log_ids) THEN
    INSERT INTO activity_logs (
      actor_id, actor_email, action, target_type,
      target_id, target_label, details
    ) VALUES (
      v_uid, v_email,
      'activity_logs_delete_attempt_unauthorized',
      'activity_log', NULL, 'attempted',
      jsonb_build_object(
        'log_ids', p_log_ids,
        'reason',  p_reason,
        'count',   array_length(p_log_ids, 1)
      )
    );
    RAISE EXCEPTION 'Non autorisé : super-admin ou propriétaire requis pour supprimer ces logs';
  END IF;

  -- Préserver le compte AVANT le delete pour le log d'audit.
  SELECT COUNT(*) INTO v_count
    FROM activity_logs WHERE id::text = ANY(p_log_ids);

  -- Audit AVANT le delete : sinon le log d'audit pourrait référencer des
  -- ids qui n'existent plus. On le pose AVANT, le log d'audit lui-même
  -- n'est pas dans la liste à supprimer (id différent, juste créé).
  INSERT INTO activity_logs (
    actor_id, actor_email, action, target_type,
    target_id, target_label, details
  ) VALUES (
    v_uid, v_email, 'activity_logs_deleted',
    'activity_log', NULL, 'deleted',
    jsonb_build_object(
      'count',   v_count,
      'reason',  p_reason,
      'log_ids', p_log_ids
    )
  );

  DELETE FROM activity_logs WHERE id::text = ANY(p_log_ids);

  RETURN jsonb_build_object('deleted', v_count);
END $del$;

REVOKE ALL ON FUNCTION public.delete_activity_logs(TEXT[], TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_activity_logs(TEXT[], TEXT) TO authenticated;
