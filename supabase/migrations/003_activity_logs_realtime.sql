-- ═══════════════════════════════════════════════════════════════════════════
-- Fortress — Migration 003 : activer Realtime sur activity_logs
-- Ajoute activity_logs à la publication supabase_realtime pour que les INSERT
-- soient diffusés en temps réel aux clients abonnés.
-- Idempotent : vérifie d'abord que la table n'est pas déjà publiée.
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename  = 'activity_logs'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE activity_logs;
  END IF;
END $mig$;
