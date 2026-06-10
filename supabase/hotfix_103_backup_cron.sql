-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_103_backup_cron.sql  —  Cron quotidien de sauvegarde (Étape B)
--
-- Planifie un appel quotidien à l'edge function `shop-backup` en mode
-- snapshot-all (sauvegarde toutes les boutiques backup_enabled = true).
--
-- PRÉREQUIS :
--   1. hotfix_102 appliqué.
--   2. Edge function déployée :  supabase functions deploy shop-backup
--   3. Secret cron posé côté edge ET ici (DOIT être identique) :
--        supabase secrets set CRON_SECRET=<chaine-longue-aleatoire>
--      → remplace <CRON_SECRET_ICI> ci-dessous par la MÊME valeur.
--
-- À exécuter dans le SQL Editor. Réexécutable (unschedule avant reschedule).
-- ════════════════════════════════════════════════════════════════════════════

-- Extensions nécessaires (déjà présentes sur Supabase, idempotent).
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

-- Supprime un éventuel job existant du même nom (évite les doublons).
SELECT cron.unschedule('daily-shop-backups')
WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'daily-shop-backups');

-- Planifie tous les jours à 02:00 UTC.
SELECT cron.schedule(
  'daily-shop-backups',
  '0 2 * * *',
  $cron$
  SELECT net.http_post(
    url     := 'https://hyxvussnlnvbkalqzovb.supabase.co/functions/v1/shop-backup',
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'x-cron-secret', 'JbhaNCmPxzUcMWZ3G0QieVftR8HXkd46jLErgq2AoOuwYv1n'),
    body    := jsonb_build_object('mode', 'snapshot-all')
  );
  $cron$
);

-- Vérifs utiles :
--   SELECT jobname, schedule, active FROM cron.job WHERE jobname = 'daily-shop-backups';
--   SELECT * FROM cron.job_run_details WHERE jobid =
--     (SELECT jobid FROM cron.job WHERE jobname='daily-shop-backups')
--     ORDER BY start_time DESC LIMIT 5;
