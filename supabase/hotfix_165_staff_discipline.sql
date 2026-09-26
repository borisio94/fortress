-- hotfix_165_staff_discipline.sql
-- ═════════════════════════════════════════════════════════════════════════
-- TENIR SON ÉQUIPE — horaires, heures supplémentaires, casse, notation,
-- primes spéciales.
--
-- Jusqu'ici le module Personnel savait trois choses : qui travaille, combien
-- de minutes, combien on lui doit à la fin du mois. Il ne savait rien de ce
-- qui occupe RÉELLEMENT un gérant de restaurant :
--
--   * un employé part une heure plus tôt — avec ou sans raison valable ;
--   * un autre reste jusqu'à 2 h du matin un soir de grande affluence, et
--     ces heures-là se paient, à un taux qui n'est pas le même pour un
--     plongeur et pour un chef ;
--   * quelqu'un casse le blender à 45 000 F ;
--   * un client se plaint d'un serveur, et c'est la troisième fois ;
--   * le patron veut lancer « le meilleur vendeur de chawarmas de la
--     quinzaine gagne 20 000 F ».
--
-- Tout cela se réglait de mémoire, se discutait en fin de mois et finissait
-- en conflit — parce que rien n'en gardait la trace au moment où c'est
-- arrivé. C'est le seul objet de ce correctif : écrire les faits au moment
-- où ils se produisent, pour que la paie n'ait plus à être négociée.
--
-- CE QUI N'EST PAS FAIT ICI, VOLONTAIREMENT : aucune sanction automatique.
-- Une excuse refusée ne retient pas un franc toute seule, une note basse ne
-- licencie personne. L'application constate et propose ; l'argent ne bouge
-- que sur un geste du gérant.
--
-- 100 % idempotent (ré-exécutable sans effet de bord).
-- ═════════════════════════════════════════════════════════════════════════

-- Garde-fou : la RLS de toutes les tables ci-dessous dépend du helper de
-- hotfix_041.
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
-- 1. HORAIRE DE L'ÉTABLISSEMENT — l'heure de référence.
-- ══════════════════════════════════════════════════════════════════════════
--
-- Sans heure de fermeture, aucun départ n'est ni anticipé ni supplémentaire :
-- il n'y a rien à comparer. C'est la donnée qui commande tout le reste, et
-- elle doit être la MÊME sur la tablette de la salle et sur le téléphone du
-- gérant — d'où une table synchronisée plutôt qu'une préférence d'appareil
-- (la leçon du fond de caisse, hotfix_147 : deux appareils, deux réglages,
-- deux totaux attendus, et un écart imaginaire).

CREATE TABLE IF NOT EXISTS public.staff_settings (
  shop_id      TEXT PRIMARY KEY
                 REFERENCES public.shops(id) ON DELETE CASCADE,
  -- 'HH:mm'. NULL = aucun horaire réglé : rien n'est jugé.
  closing_time TEXT,
  updated_at   TIMESTAMPTZ DEFAULT now()
);

COMMENT ON TABLE public.staff_settings IS
  'Réglages du personnel par boutique (hotfix_165). Une ligne par boutique.';
COMMENT ON COLUMN public.staff_settings.closing_time IS
  'Heure de fin de service de l''établissement, ''HH:mm''. Référence du '
  'départ anticipé et des heures supplémentaires. NULL = rien n''est jugé.';

-- Horaire PROPRE à un employé : le boulanger qui part à 11 h, le veilleur qui
-- prend à la fermeture. Sans cette surcharge, ces gens-là accumuleraient
-- chaque jour des heures supplémentaires imaginaires.
ALTER TABLE public.employees
  ADD COLUMN IF NOT EXISTS closing_time TEXT;

COMMENT ON COLUMN public.employees.closing_time IS
  'Heure de fin de service propre à cet employé, ''HH:mm'' (hotfix_165). '
  'NULL = suit l''horaire de l''établissement (staff_settings.closing_time).';

-- ══════════════════════════════════════════════════════════════════════════
-- 2. TAUX DES HEURES SUPPLÉMENTAIRES — par FONCTION.
-- ══════════════════════════════════════════════════════════════════════════
--
-- Sur le poste et non sur la personne : un restaurant paie l'heure d'un
-- cuisinier plus cher que celle d'un plongeur, mais tous ses cuisiniers au
-- même tarif. Adossé à l'employé, le taux serait à ressaisir à chaque
-- embauche et deux serveurs finiraient payés différemment sans que personne
-- ne l'ait décidé.

ALTER TABLE public.job_titles
  ADD COLUMN IF NOT EXISTS overtime_rate INTEGER NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.job_titles.overtime_rate IS
  'Taux horaire des heures supplémentaires de ce poste, en FCFA (hotfix_165). '
  '0 = non réglé : aucune heure supplémentaire n''est valorisée pour ce '
  'poste, elles restent comptées en minutes.';

-- ══════════════════════════════════════════════════════════════════════════
-- 3. POINTAGE — la sortie est désormais JUGÉE.
-- ══════════════════════════════════════════════════════════════════════════
--
-- Tout est FIGÉ à la sortie : l'heure de référence, les minutes, le taux, le
-- montant. Recalculer à la lecture ferait bouger les heures supplémentaires
-- de septembre le jour où le gérant change son horaire en novembre.

ALTER TABLE public.time_records
  ADD COLUMN IF NOT EXISTS scheduled_end       TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS early_minutes       INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS early_excuse        TEXT,
  ADD COLUMN IF NOT EXISTS excuse_status       TEXT    NOT NULL DEFAULT 'none',
  ADD COLUMN IF NOT EXISTS overtime_minutes    INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS overtime_rate       INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS overtime_amount     INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS overtime_settlement TEXT    NOT NULL DEFAULT 'pending',
  ADD COLUMN IF NOT EXISTS overtime_settled    BOOLEAN NOT NULL DEFAULT false;

-- Les CHECK sont posés à part et de façon idempotente : ADD CONSTRAINT IF NOT
-- EXISTS n'existe pas en Postgres.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'time_records_excuse_status_chk') THEN
    ALTER TABLE public.time_records
      ADD CONSTRAINT time_records_excuse_status_chk
      CHECK (excuse_status IN ('none','pending','accepted','refused'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'time_records_ot_settlement_chk') THEN
    ALTER TABLE public.time_records
      ADD CONSTRAINT time_records_ot_settlement_chk
      CHECK (overtime_settlement IN ('pending','paid_now','on_payslip'));
  END IF;
END $$;

COMMENT ON COLUMN public.time_records.excuse_status IS
  'Départ anticipé : none | pending (excuse à juger) | accepted | refused '
  '(hotfix_165). Un refus ne retient RIEN automatiquement — il signale.';
COMMENT ON COLUMN public.time_records.overtime_settled IS
  'true une fois les heures supplémentaires effectivement versées ou portées '
  'sur une fiche de paie. Même rôle que salary_advances.is_deducted : sans '
  'lui, les mêmes heures seraient payées à chaque génération de fiche.';

-- Les décisions qui restent à prendre : c'est la seule liste que le gérant
-- consulte. Index partiels → ils ne grossissent pas avec l'historique.
CREATE INDEX IF NOT EXISTS time_records_excuse_pending_idx
  ON public.time_records(shop_id)
  WHERE excuse_status = 'pending';
CREATE INDEX IF NOT EXISTS time_records_overtime_due_idx
  ON public.time_records(shop_id, employee_id)
  WHERE overtime_minutes > 0 AND overtime_settled = false;

-- ══════════════════════════════════════════════════════════════════════════
-- 4. QUINZAINE — un droit, pas une faveur.
-- ══════════════════════════════════════════════════════════════════════════
--
-- Même table que les avances (même sortie de caisse, même retenue sur la même
-- paie), mais pas la même chose : la quinzaine se touche SANS SE JUSTIFIER,
-- l'avance se motive. Les confondre obligerait à inventer un motif à un droit.

ALTER TABLE public.salary_advances
  ADD COLUMN IF NOT EXISTS kind TEXT NOT NULL DEFAULT 'advance';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'salary_advances_kind_chk') THEN
    ALTER TABLE public.salary_advances
      ADD CONSTRAINT salary_advances_kind_chk
      CHECK (kind IN ('advance','fortnight'));
  END IF;
END $$;

COMMENT ON COLUMN public.salary_advances.kind IS
  'advance (motivée, à tout moment) | fortnight (quinzaine, sans motif, '
  'plafonnée à la moitié du salaire de base) — hotfix_165.';

-- ══════════════════════════════════════════════════════════════════════════
-- 5. PAIE — d'où vient le net, ligne par ligne.
-- ══════════════════════════════════════════════════════════════════════════
--
-- Heures supplémentaires et casse SÉPARÉES des primes et des retenues
-- saisies à la main : ce sont les deux lignes qu'un employé vérifie en
-- premier. Fondues dans un seul nombre, la fiche devient invérifiable — donc
-- suspecte.

ALTER TABLE public.payroll
  ADD COLUMN IF NOT EXISTS overtime_amount    INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS overtime_minutes   INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS penalties_deducted INTEGER DEFAULT 0;

COMMENT ON COLUMN public.payroll.overtime_amount IS
  'Heures supplémentaires reportées sur cette fiche (hotfix_165). Détail : '
  'time_records du mois avec overtime_settlement = ''on_payslip''.';
COMMENT ON COLUMN public.payroll.penalties_deducted IS
  'Retenues pour casse sur cette fiche. Détail : staff_penalties.';

-- ══════════════════════════════════════════════════════════════════════════
-- 6. CASSE IMPUTÉE — le bien détruit et la façon de le récupérer.
-- ══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.staff_penalties (
  id                TEXT PRIMARY KEY,
  shop_id           TEXT NOT NULL
                      REFERENCES public.shops(id) ON DELETE CASCADE,
  employee_id       TEXT    NOT NULL,   -- ref logique vers employees
  employee_name     TEXT,
  item_label        TEXT    NOT NULL,
  amount            INTEGER NOT NULL,
  -- one_shot : tout sur la prochaine paie.
  -- installments : percent_per_month % du MONTANT chaque mois, jusqu'à solde.
  --   Du montant et non du salaire : « 25 % » se lit « quatre mois », une
  --   durée que l'employé peut vérifier — adossée au salaire, elle changerait
  --   à chaque augmentation.
  -- cash_repaid : remboursé de sa poche, le salaire n'est JAMAIS touché.
  mode              TEXT    NOT NULL DEFAULT 'one_shot',
  percent_per_month INTEGER NOT NULL DEFAULT 25,
  amount_recovered  INTEGER NOT NULL DEFAULT 0,
  start_month       TEXT    NOT NULL,   -- 'YYYY-MM'
  -- Obligatoire : une retenue sur salaire sans motif écrit est indéfendable
  -- le jour où elle est contestée.
  reason            TEXT    NOT NULL,
  incident_date     DATE    NOT NULL DEFAULT CURRENT_DATE,
  closed_at         TIMESTAMPTZ,
  schema_version    INTEGER,
  created_at        TIMESTAMPTZ DEFAULT now()
);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'staff_penalties_mode_chk') THEN
    ALTER TABLE public.staff_penalties
      ADD CONSTRAINT staff_penalties_mode_chk
      CHECK (mode IN ('one_shot','installments','cash_repaid'));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS staff_penalties_shop_idx
  ON public.staff_penalties(shop_id, incident_date DESC);
-- Les dettes encore vivantes : la seule liste consultée à la paie.
CREATE INDEX IF NOT EXISTS staff_penalties_open_idx
  ON public.staff_penalties(shop_id, employee_id)
  WHERE closed_at IS NULL;

-- ══════════════════════════════════════════════════════════════════════════
-- 7. NOTATION — des ÉVÉNEMENTS, jamais une note.
-- ══════════════════════════════════════════════════════════════════════════
--
-- Ce qui est stocké est le fait, pas le résultat : « −2, plainte du client de
-- la table 4 sur le temps d'attente, jugée fondée ». La note (10 moins les
-- points perdus du mois) se redéduit à tout moment.
--
-- Pourquoi pas un compteur sur la fiche : une note seule ne se conteste pas.
-- L'employé descendu à 6 a le droit de savoir quelles trois décisions l'y ont
-- mené, et le gérant qui s'est trompé doit pouvoir en retirer une sans avoir
-- à recalculer quoi que ce soit.
--
-- La remise à 10 est MENSUELLE, et elle ne s'écrit nulle part : elle découle
-- du filtre sur `month`. Une faute de janvier cesse de peser le 1er février
-- sans qu'aucune tâche planifiée n'ait à passer.

CREATE TABLE IF NOT EXISTS public.staff_ratings (
  id             TEXT PRIMARY KEY,
  shop_id        TEXT NOT NULL
                   REFERENCES public.shops(id) ON DELETE CASCADE,
  employee_id    TEXT    NOT NULL,   -- ref logique vers employees
  employee_name  TEXT,
  -- SIGNÉ : négatif = sanction, positif = employé modèle.
  points         INTEGER NOT NULL,
  reason         TEXT    NOT NULL,
  source         TEXT    NOT NULL DEFAULT 'other',
  month          TEXT    NOT NULL,   -- 'YYYY-MM'
  schema_version INTEGER,
  created_at     TIMESTAMPTZ DEFAULT now()
);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'staff_ratings_source_chk') THEN
    ALTER TABLE public.staff_ratings
      ADD CONSTRAINT staff_ratings_source_chk
      CHECK (source IN ('complaint','bonus','other'));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS staff_ratings_shop_month_idx
  ON public.staff_ratings(shop_id, month);
CREATE INDEX IF NOT EXISTS staff_ratings_employee_idx
  ON public.staff_ratings(employee_id, month);

-- ══════════════════════════════════════════════════════════════════════════
-- 8. PRIMES SPÉCIALES — un concours à durée déterminée.
-- ══════════════════════════════════════════════════════════════════════════
--
-- Conditions en TEXTE LIBRE et vainqueur désigné à la main : vouloir les
-- évaluer automatiquement supposerait que l'application sache mesurer « le
-- plus souriant » ou « le plus ponctuel ». Elle ne le sait pas — et un
-- concours qu'on ne peut pas énoncer librement ne serait jamais lancé.
--
-- La prime se verse À CÔTÉ du salaire et n'entre JAMAIS dans le calcul du
-- net : sinon elle deviendrait un acquis que l'employé réclamerait le mois
-- suivant.

CREATE TABLE IF NOT EXISTS public.staff_contests (
  id             TEXT PRIMARY KEY,
  shop_id        TEXT NOT NULL
                   REFERENCES public.shops(id) ON DELETE CASCADE,
  title          TEXT    NOT NULL,
  conditions     TEXT,
  prize          INTEGER NOT NULL DEFAULT 0,
  start_date     DATE    NOT NULL,
  end_date       DATE    NOT NULL,
  winner_id      TEXT,               -- ref logique vers employees
  winner_name    TEXT,               -- figé : le palmarès survit à la fiche
  awarded_at     TIMESTAMPTZ,
  paid_at        TIMESTAMPTZ,
  -- Versée en espèces : elle sort du tiroir et la clôture de caisse doit la
  -- déduire, exactement comme une avance.
  paid_cash      BOOLEAN DEFAULT true,
  schema_version INTEGER,
  created_at     TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS staff_contests_shop_idx
  ON public.staff_contests(shop_id, end_date DESC);

-- ══════════════════════════════════════════════════════════════════════════
-- 9. RLS + Realtime pour les quatre nouvelles tables.
-- ══════════════════════════════════════════════════════════════════════════
--
-- Realtime indispensable ici : la badgeuse est un appareil (l'excuse s'y
-- saisit), la paie s'ouvre sur un autre (le gérant y juge). Sans propagation,
-- le gérant ne verrait jamais l'excuse qu'il doit trancher.

DO $$
DECLARE
  t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'staff_settings','staff_penalties','staff_ratings','staff_contests'
  ] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY;', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I;', t || '_members', t);
    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR ALL TO authenticated '
      'USING (public._is_shop_member(shop_id)) '
      'WITH CHECK (public._is_shop_member(shop_id));',
      t || '_members', t);

    IF NOT EXISTS (
      SELECT 1 FROM pg_publication_tables
       WHERE pubname = 'supabase_realtime'
         AND schemaname = 'public'
         AND tablename  = t
    ) THEN
      EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I;', t);
    END IF;
  END LOOP;
END $$;

-- ── Vérification ─────────────────────────────────────────────────────────
--
--   SELECT tablename, rowsecurity FROM pg_tables
--    WHERE schemaname='public'
--      AND tablename IN ('staff_settings','staff_penalties',
--                        'staff_ratings','staff_contests');
--
--   -- Décisions en attente du gérant :
--   SELECT employee_name, clock_out, early_minutes, early_excuse
--     FROM public.time_records
--    WHERE shop_id='<shop>' AND excuse_status='pending'
--    ORDER BY clock_out DESC;
--
--   -- Heures supplémentaires dues, non encore réglées :
--   SELECT employee_name,
--          sum(overtime_minutes)/60.0 AS heures,
--          sum(overtime_amount)       AS montant
--     FROM public.time_records
--    WHERE shop_id='<shop>' AND overtime_settled = false
--      AND overtime_minutes > 0
--    GROUP BY employee_name;
--
--   -- Classement du mois (10 points de base + somme des événements) :
--   SELECT e.full_name,
--          10 + COALESCE(sum(r.points), 0) AS note_brute
--     FROM public.employees e
--     LEFT JOIN public.staff_ratings r
--            ON r.employee_id = e.id AND r.month = to_char(now(), 'YYYY-MM')
--    WHERE e.shop_id = '<shop>' AND e.is_active
--    GROUP BY e.full_name
--    ORDER BY note_brute DESC;
--
--   -- Casse en cours de récupération :
--   SELECT employee_name, item_label, amount, amount_recovered, mode
--     FROM public.staff_penalties
--    WHERE shop_id='<shop>' AND closed_at IS NULL;
--
-- Fin — hotfix_165_staff_discipline.sql
