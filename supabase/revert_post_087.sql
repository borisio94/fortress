-- ════════════════════════════════════════════════════════════════════════════
-- revert_post_087.sql
--
-- Annule toutes les modifications Supabase appliquées par hotfix_088, 089, 090
-- (et 091 s'il a été appliqué). Ramène le schéma à l'état exact à la fin de
-- hotfix_087.
--
-- Hotfixes annulés (du + récent au + ancien — ordre de DROP) :
--   • hotfix_090_super_admin_pr3 : broadcasts + incidents.severity
--   • hotfix_089_super_admin_pr2 : extend_trial + payment_records + record_payment
--   • hotfix_088_super_admin_pr1 : suspend/reactivate shop + upsert_plan + plans RLS
--   • hotfix_091_partner_ledger_policy_hardening : (untracked, peut ne pas être appliqué)
--
-- ⚠ DESTRUCTIF — perte de données :
--   • Toutes les lignes de `broadcasts` seront supprimées (DROP TABLE)
--   • Toutes les lignes de `payment_records` seront supprimées (DROP TABLE)
--   • La colonne `shops.status` sera supprimée → les boutiques suspendues
--     redeviennent indistinguables des actives (l'info de suspension est perdue)
--   • La colonne `incidents.severity` sera supprimée → l'historique de
--     classification normal/critique est perdu
--   • Les entrées de `activity_logs` créées par ces RPC RESTENT (référence
--     logique uniquement, pas de FK)
--
-- Idempotent : tous les DROP utilisent IF EXISTS.
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- 1. REVERT hotfix_091_partner_ledger_policy_hardening (au cas où)
-- ════════════════════════════════════════════════════════════════════════════
-- Si jamais ce hotfix a été appliqué : on ne sait pas son contenu exact
-- (untracked). À adapter si besoin. Décommenter et compléter si pertinent.
-- DROP POLICY IF EXISTS partner_ledger_policy_hardened ON public.partner_ledger_entries;


-- ════════════════════════════════════════════════════════════════════════════
-- 2. REVERT hotfix_090_super_admin_pr3 — broadcasts + incidents.severity
-- ════════════════════════════════════════════════════════════════════════════

-- SA-7 : retirer la lecture super-admin sur incidents
DROP POLICY IF EXISTS "incidents_superadmin_read" ON public.incidents;

-- SA-7 : retirer la colonne severity + son CHECK
ALTER TABLE public.incidents DROP CONSTRAINT IF EXISTS incidents_severity_check;
ALTER TABLE public.incidents DROP COLUMN IF EXISTS severity;

-- SA-5 : retirer la RPC d'envoi de broadcast
DROP FUNCTION IF EXISTS public.send_broadcast(TEXT, TEXT, TEXT, TEXT, TEXT);

-- SA-5 : retirer la policy + la table broadcasts
DROP POLICY IF EXISTS "broadcasts_read" ON public.broadcasts;
DROP TABLE IF EXISTS public.broadcasts;  -- supprime aussi l'index broadcasts_sent_idx


-- ════════════════════════════════════════════════════════════════════════════
-- 3. REVERT hotfix_089_super_admin_pr2 — extend_trial + payment_records
-- ════════════════════════════════════════════════════════════════════════════

-- SA-4 : retirer la RPC d'enregistrement de paiement
DROP FUNCTION IF EXISTS public.record_payment(
  TEXT, UUID, NUMERIC, TEXT, TEXT, TEXT, TEXT, BOOLEAN, INT
);

-- SA-4 : retirer la policy + la table payment_records
DROP POLICY IF EXISTS "payment_records_read" ON public.payment_records;
DROP TABLE IF EXISTS public.payment_records;  -- supprime aussi payment_records_shop_idx

-- SA-3 : retirer la RPC extend_trial
DROP FUNCTION IF EXISTS public.extend_trial(TEXT, INT);


-- ════════════════════════════════════════════════════════════════════════════
-- 4. REVERT hotfix_088_super_admin_pr1 — suspend/reactivate + upsert_plan
-- ════════════════════════════════════════════════════════════════════════════

-- Retirer la policy de lecture publique des plans ajoutée par 088
-- (la policy `plans_select` de hotfix_017 reste en place et continue de
-- couvrir les lectures → aucun risque de bloquer les lectures de plans).
DROP POLICY IF EXISTS "plans_read_all" ON public.plans;

-- SA-2 : retirer la RPC d'upsert de plan
DROP FUNCTION IF EXISTS public.upsert_plan(
  UUID, TEXT, TEXT, NUMERIC, NUMERIC, NUMERIC, INT, INT, INT,
  JSONB, BOOLEAN, INT, BOOLEAN
);

-- SA-1 : retirer les RPC de suspension / réactivation
DROP FUNCTION IF EXISTS public.reactivate_shop(TEXT);
DROP FUNCTION IF EXISTS public.suspend_shop(TEXT, TEXT);

-- SA-1 : retirer les colonnes de suspension sur shops
ALTER TABLE public.shops DROP COLUMN IF EXISTS suspended_reason;
ALTER TABLE public.shops DROP COLUMN IF EXISTS suspended_at;
ALTER TABLE public.shops DROP CONSTRAINT IF EXISTS shops_status_check;
ALTER TABLE public.shops DROP COLUMN IF EXISTS status;


-- ════════════════════════════════════════════════════════════════════════════
-- 5. Rechargement du cache de schéma PostgREST
-- ════════════════════════════════════════════════════════════════════════════
NOTIFY pgrst, 'reload schema';

COMMIT;

-- ── Vérifications post-revert (à lancer séparément après COMMIT) ───────────
-- Confirme que tout a bien été retiré :
--
--   SELECT table_name FROM information_schema.tables
--    WHERE table_schema = 'public'
--      AND table_name IN ('broadcasts', 'payment_records');
--   -- → 0 lignes attendues
--
--   SELECT column_name FROM information_schema.columns
--    WHERE table_schema = 'public' AND table_name = 'shops'
--      AND column_name IN ('status', 'suspended_at', 'suspended_reason');
--   -- → 0 lignes attendues
--
--   SELECT column_name FROM information_schema.columns
--    WHERE table_schema = 'public' AND table_name = 'incidents'
--      AND column_name = 'severity';
--   -- → 0 ligne attendue
--
--   SELECT proname FROM pg_proc
--    WHERE pronamespace = 'public'::regnamespace
--      AND proname IN ('suspend_shop','reactivate_shop','upsert_plan',
--                      'extend_trial','record_payment','send_broadcast');
--   -- → 0 lignes attendues
