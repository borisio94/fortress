-- hotfix_148_staff_timeclock_payroll.sql
-- ═════════════════════════════════════════════════════════════════════════
-- PERSONNEL : POINTAGE, AVANCES ET PAIE (Lot D du cahier des charges).
--
-- Complète les tables `employees` et `payroll` créées vides par hotfix_140, et
-- ajoute les deux tables qui manquaient : le pointage et les avances.
--
-- QUI EST UN « EMPLOYÉ » ICI — le point à ne pas confondre. Fortress a DEUX
-- notions distinctes, et elles ne doivent pas être fusionnées :
--   * `shop_memberships` + `profiles` (module RH existant) = les UTILISATEURS
--     de l'application : ils ont un compte, un mot de passe, des permissions.
--   * `employees` (ici) = le PERSONNEL du restaurant : serveuses, cuisiniers,
--     plongeurs. Ils ne se connectent jamais à l'app. Ils ont un salaire, des
--     heures et des avances. Exiger un compte pour chacun rendrait le module
--     inutilisable — personne ne crée un compte e-mail à un plongeur.
--
-- POINTAGE PAR PIN — le PIN est HACHÉ (SHA-256 + sel par employé), jamais
-- stocké en clair, alors que la spec le prévoyait tel quel. Ces lignes sont
-- synchronisées sur tous les appareils de la boutique : un PIN lisible dans la
-- base, c'est un pointage falsifiable par quiconque ouvre l'écran des
-- employés. La vérification balaie les employés actifs et compare les hachages
-- (quelques dizaines de lignes : le coût est nul).
--
-- ÉCART ASSUMÉ : pas de CHECK sur `employees.role`. Les rôles d'un restaurant
-- camerounais ne tiennent pas dans une liste figée (« boy », « caissière-
-- serveuse », « aide-cuisine »…), et un CHECK trop étroit ferait rejeter
-- l'upsert — opération abandonnée après dix essais, en silence. Une liste
-- SUGGÉRÉE est proposée côté application, sans interdire la saisie libre.
--
-- Conventions (alignées sur hotfix_140 / _145 / _146 / _147) : PK TEXT `tc_` /
-- `sa_` + microsecondes générée côté client (offline-first), montants INTEGER
-- (FCFA), PAS de FK inter-entités, RLS membres, Realtime.
--
-- 100 % idempotent (ré-exécutable sans effet de bord).
-- ═════════════════════════════════════════════════════════════════════════

-- Garde-fou : la RLS dépend du helper de hotfix_041.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc
     WHERE proname = '_is_shop_member'
       AND pronamespace = 'public'::regnamespace
  ) THEN
    RAISE EXCEPTION
      'public._is_shop_member() manquante — appliquer hotfix_041 d''abord.';
  END IF;
END $$;

-- ══════════════════════════════════════════════════════════════════════════
-- 1. EMPLOYÉS — PIN de pointage (haché) et informations de paie.
-- ══════════════════════════════════════════════════════════════════════════
ALTER TABLE public.employees
  ADD COLUMN IF NOT EXISTS pin_hash TEXT,
  ADD COLUMN IF NOT EXISTS pin_salt TEXT,
  -- Repère libre : « Cuisine », « Salle », « Bar ». Sert à regrouper les
  -- pointages et la masse salariale par poste sans imposer de référentiel.
  ADD COLUMN IF NOT EXISTS station TEXT;

COMMENT ON COLUMN public.employees.pin_hash IS
  'SHA-256(sel:PIN) du code de pointage à 4 chiffres. Jamais le PIN en clair : '
  'ces lignes sont synchronisées sur tous les appareils de la boutique.';

-- ══════════════════════════════════════════════════════════════════════════
-- 2. POINTAGE — une ligne par service (entrée, puis sortie).
-- ══════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.time_records (
  id               TEXT PRIMARY KEY,
  shop_id          TEXT NOT NULL
                     REFERENCES public.shops(id) ON DELETE CASCADE,
  -- Ref logique vers employees (pas de FK, cf. en-tête de hotfix_140).
  employee_id      TEXT NOT NULL,
  -- Nom figé : un employé parti l'an dernier doit rester lisible dans
  -- l'historique des heures, même si sa fiche a été supprimée.
  employee_name    TEXT,
  clock_in         TIMESTAMPTZ,
  clock_out        TIMESTAMPTZ,
  -- Durée FIGÉE à la sortie, en minutes. Stockée plutôt que recalculée :
  -- un pointage corrigé à la main garde la durée validée par le gérant.
  duration_minutes INTEGER,
  method           TEXT DEFAULT 'pin'
                     CHECK (method IN ('pin','qr_code','manual')),
  note             TEXT,
  schema_version   INTEGER,
  created_at       TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS time_records_shop_idx
  ON public.time_records(shop_id, clock_in DESC);
CREATE INDEX IF NOT EXISTS time_records_employee_idx
  ON public.time_records(employee_id, clock_in DESC);
-- Le service EN COURS d'un employé : lu à chaque badge pour savoir s'il entre
-- ou s'il sort. Index partiel → il ne grossit pas avec l'historique.
CREATE INDEX IF NOT EXISTS time_records_open_idx
  ON public.time_records(shop_id, employee_id)
  WHERE clock_out IS NULL;

-- ══════════════════════════════════════════════════════════════════════════
-- 3. AVANCES SUR SALAIRE — versées en cours de mois, déduites à la paie.
-- ══════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.salary_advances (
  id                  TEXT PRIMARY KEY,
  shop_id             TEXT NOT NULL
                        REFERENCES public.shops(id) ON DELETE CASCADE,
  employee_id         TEXT    NOT NULL,   -- ref logique vers employees
  employee_name       TEXT,
  amount              INTEGER NOT NULL,
  reason              TEXT,
  advance_date        DATE    NOT NULL DEFAULT CURRENT_DATE,
  -- Mois de paie sur lequel l'avance sera retenue, au format 'YYYY-MM'.
  -- Rempli à la création (mois de l'avance) et modifiable : une avance de fin
  -- de mois se retient souvent sur le mois suivant.
  deducted_from_month TEXT,
  is_deducted         BOOLEAN DEFAULT false,
  schema_version      INTEGER,
  created_at          TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS salary_advances_shop_idx
  ON public.salary_advances(shop_id, advance_date DESC);
CREATE INDEX IF NOT EXISTS salary_advances_employee_idx
  ON public.salary_advances(employee_id);
-- Les avances PAS ENCORE retenues : la seule liste qui compte au moment de
-- préparer la paie.
CREATE INDEX IF NOT EXISTS salary_advances_pending_idx
  ON public.salary_advances(shop_id, deducted_from_month)
  WHERE is_deducted = false;

-- ══════════════════════════════════════════════════════════════════════════
-- 4. PAIE — traçabilité de ce qui compose le net.
-- ══════════════════════════════════════════════════════════════════════════
-- Sans ces deux colonnes, une fiche de paie affiche un net sans qu'on puisse
-- dire d'où vient l'écart avec le salaire de base — et l'employé qui conteste
-- a raison de le faire.
ALTER TABLE public.payroll
  ADD COLUMN IF NOT EXISTS advances_deducted INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS minutes_worked    INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS employee_name     TEXT;

COMMENT ON COLUMN public.payroll.advances_deducted IS
  'Total des avances retenues sur cette fiche. Détail : salary_advances '
  'filtrées sur deducted_from_month = payroll.month.';
COMMENT ON COLUMN public.payroll.minutes_worked IS
  'Minutes pointées sur le mois (time_records). Informatif : aucune prime '
  'd''heures supplémentaires n''est calculée automatiquement — le taux dépend '
  'd''un accord que l''application ne connaît pas.';

-- ── RLS : membres / owner / super-admin (lecture + écriture) ───────────────
DO $$
DECLARE
  t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['time_records','salary_advances'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY;', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I;', t || '_members', t);
    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR ALL TO authenticated '
      'USING (public._is_shop_member(shop_id)) '
      'WITH CHECK (public._is_shop_member(shop_id));',
      t || '_members', t);
  END LOOP;
END $$;

-- ── Realtime : la badgeuse est un appareil, la paie s'ouvre sur un autre ───
DO $$
DECLARE
  t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['time_records','salary_advances'] LOOP
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

-- ── Vérification ───────────────────────────────────────────────────────────
--   SELECT tablename, rowsecurity FROM pg_tables
--    WHERE schemaname='public' AND tablename IN ('time_records','salary_advances');
--
--   -- Qui est actuellement en service :
--   SELECT employee_name, clock_in FROM public.time_records
--    WHERE shop_id='<shop>' AND clock_out IS NULL ORDER BY clock_in;
--
--   -- Heures du mois par employé :
--   SELECT employee_name, sum(duration_minutes)/60.0 AS heures
--     FROM public.time_records
--    WHERE shop_id='<shop>' AND clock_in >= date_trunc('month', now())
--    GROUP BY employee_name ORDER BY heures DESC;
--
--   -- Avances à retenir sur la paie de juillet :
--   SELECT employee_name, sum(amount) FROM public.salary_advances
--    WHERE shop_id='<shop>' AND deducted_from_month='2026-07' AND NOT is_deducted
--    GROUP BY employee_name;
--
-- Fin — hotfix_148_staff_timeclock_payroll.sql
