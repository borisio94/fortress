-- hotfix_166_staff_absences.sql
-- ═════════════════════════════════════════════════════════════════════════
-- ABSENCES DÉCIDÉES — mise à pied, congé payé, et suppression motivée.
--
-- hotfix_165 a appris à l'application à CONSTATER des écarts sur un pointage :
-- parti trop tôt, resté trop tard. Il lui manque l'autre moitié — ce que le
-- gérant DÉCIDE :
--
--   * écarter quelqu'un du service quelques jours, avec ou sans solde ;
--   * lui accorder un congé payé ;
--   * supprimer définitivement une fiche.
--
-- Les trois ont la même exigence : un MOTIF ÉCRIT. C'est la seule chose qui
-- reste le jour où la décision est contestée — et, pour la suppression, la
-- seule trace de ce qui a disparu.
--
-- POURQUOI UNE SEULE TABLE pour la mise à pied et le congé : les deux couvrent
-- des journées entières, exigent un motif, interdisent le badgeage et peuvent
-- toucher la paie. Elles ne diffèrent que par ce qu'elles racontent. Deux
-- tables auraient dupliqué le calendrier, le calcul de retenue et le contrôle
-- de la badgeuse pour ne gagner qu'un libellé.
--
-- CE QUI N'EST PAS FAIT ICI : aucune suppression en cascade. Supprimer un
-- employé retire SA FICHE, jamais ses pointages ni ses bulletins — ceux-ci
-- portent son nom figé et restent lisibles. Effacer l'historique changerait
-- rétroactivement des masses salariales et des clôtures de caisse déjà
-- vérifiées.
--
-- 100 % idempotent (ré-exécutable sans effet de bord).
-- ═════════════════════════════════════════════════════════════════════════

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc
     WHERE proname = '_is_shop_member'
       AND pronamespace = 'public'::regnamespace
  ) THEN
    RAISE EXCEPTION
      'public._is_shop_member(text) manquant — appliquer hotfix_041 d''abord.';
  END IF;
END $$;

-- ══════════════════════════════════════════════════════════════════════════
-- 1. ABSENCES — mise à pied et congé payé.
-- ══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.staff_absences (
  id              TEXT PRIMARY KEY,
  shop_id         TEXT NOT NULL
                    REFERENCES public.shops(id) ON DELETE CASCADE,
  employee_id     TEXT NOT NULL,   -- ref logique vers employees
  employee_name   TEXT,
  -- suspension : l'employé est écarté du service.
  -- paid_leave  : congé, salaire maintenu intégralement.
  kind            TEXT NOT NULL DEFAULT 'paid_leave',
  -- Bornes INCLUSES : « du 10 au 12 » se compte trois jours pour tout le
  -- monde, et une absence d'un seul jour s'écrit avec la même date deux fois.
  start_date      DATE NOT NULL,
  end_date        DATE NOT NULL,
  -- Obligatoire : une mise à pied sans raison écrite est indéfendable.
  reason          TEXT NOT NULL,
  -- Le salaire est-il maintenu ? Toujours vrai pour un congé payé ; réglable
  -- pour une mise à pied, car la mise à pied CONSERVATOIRE — prononcée le
  -- temps de vérifier les faits — ne doit pas sanctionner avant d'avoir
  -- vérifié.
  is_paid         BOOLEAN NOT NULL DEFAULT false,
  -- Cumul déjà retenu sur des fiches de paie. Sans lui, une absence à cheval
  -- sur deux mois serait retenue deux fois en entier.
  amount_deducted INTEGER NOT NULL DEFAULT 0,
  -- Absence LEVÉE. La ligne est conservée : « la mise à pied a été levée » est
  -- une information, l'effacer laisserait croire qu'elle n'a jamais eu lieu.
  cancelled_at    TIMESTAMPTZ,
  schema_version  INTEGER,
  created_at      TIMESTAMPTZ DEFAULT now()
);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'staff_absences_kind_chk') THEN
    ALTER TABLE public.staff_absences
      ADD CONSTRAINT staff_absences_kind_chk
      CHECK (kind IN ('suspension','paid_leave'));
  END IF;
END $$;

COMMENT ON TABLE public.staff_absences IS
  'Absences DÉCIDÉES : mise à pied et congé payé (hotfix_166). À distinguer '
  'des écarts CONSTATÉS sur un pointage (time_records.early_minutes).';
COMMENT ON COLUMN public.staff_absences.is_paid IS
  'Salaire maintenu. Toujours true pour un congé payé ; false par défaut pour '
  'une mise à pied, true pour une mise à pied conservatoire.';

CREATE INDEX IF NOT EXISTS staff_absences_shop_idx
  ON public.staff_absences(shop_id, start_date DESC);
-- L'absence EN COURS d'un employé : lue à chaque badge pour refuser le
-- pointage. Index partiel → il ne grossit pas avec l'historique.
CREATE INDEX IF NOT EXISTS staff_absences_live_idx
  ON public.staff_absences(shop_id, employee_id, end_date)
  WHERE cancelled_at IS NULL;

-- ══════════════════════════════════════════════════════════════════════════
-- 2. PAIE — la retenue d'absence, sur sa propre ligne.
-- ══════════════════════════════════════════════════════════════════════════
--
-- Distincte de `penalties_deducted` (la casse) et de `deductions` (ce que le
-- gérant saisit à la main). Trois retenues de natures différentes fondues en
-- un seul nombre donneraient une fiche que personne ne peut vérifier — et un
-- employé qui conteste une retenue sans pouvoir la rattacher à un fait a
-- raison de le faire.

ALTER TABLE public.payroll
  ADD COLUMN IF NOT EXISTS absences_deducted INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS absence_days      INTEGER DEFAULT 0;

COMMENT ON COLUMN public.payroll.absences_deducted IS
  'Retenue pour mise à pied sans solde (hotfix_166). Détail : staff_absences. '
  'Base de calcul : salaire mensuel / 30 par jour d''absence.';

-- ══════════════════════════════════════════════════════════════════════════
-- 3. RLS + Realtime.
-- ══════════════════════════════════════════════════════════════════════════
--
-- Realtime indispensable : une mise à pied prononcée depuis le téléphone du
-- gérant doit atteindre la badgeuse de l'entrée du personnel AVANT que
-- l'intéressé n'y tape son code.

ALTER TABLE public.staff_absences ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS staff_absences_members ON public.staff_absences;
CREATE POLICY staff_absences_members ON public.staff_absences
  FOR ALL TO authenticated
  USING (public._is_shop_member(shop_id))
  WITH CHECK (public._is_shop_member(shop_id));

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
     WHERE pubname = 'supabase_realtime'
       AND schemaname = 'public'
       AND tablename  = 'staff_absences'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.staff_absences;
  END IF;
END $$;

-- ── Vérification ─────────────────────────────────────────────────────────
--
--   SELECT tablename, rowsecurity FROM pg_tables
--    WHERE schemaname='public' AND tablename='staff_absences';
--
--   -- Qui est absent aujourd'hui, et pourquoi :
--   SELECT employee_name, kind, start_date, end_date, is_paid, reason
--     FROM public.staff_absences
--    WHERE shop_id = '<shop>'
--      AND cancelled_at IS NULL
--      AND CURRENT_DATE BETWEEN start_date AND end_date
--    ORDER BY employee_name;
--
--   -- Mises à pied sans solde non encore retenues :
--   SELECT employee_name, start_date, end_date,
--          (end_date - start_date + 1) AS jours, amount_deducted
--     FROM public.staff_absences
--    WHERE shop_id = '<shop>' AND kind = 'suspension'
--      AND is_paid = false AND cancelled_at IS NULL;
--
--   -- Suppressions d'employés et leur motif (journal) :
--   SELECT created_at, actor_email, target_label, details->>'reason'
--     FROM public.activity_logs
--    WHERE shop_id = '<shop>' AND action = 'staff_deleted'
--    ORDER BY created_at DESC;
--
-- Fin — hotfix_166_staff_absences.sql
