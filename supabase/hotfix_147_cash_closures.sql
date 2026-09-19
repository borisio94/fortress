-- hotfix_147_cash_closures.sql
-- ═════════════════════════════════════════════════════════════════════════
-- CLÔTURE DE CAISSE AVEUGLE — rapports X et Z (Lot C du cahier des charges).
--
-- `cash_closures` — à chaque contrôle de caisse : ce que le caissier a COMPTÉ,
-- ce que le système ATTENDAIT, et l'écart entre les deux.
--
-- « Aveugle » est tout le principe : le caissier saisit son comptage SANS voir
-- le total attendu. S'il le voyait, un manquant deviendrait invisible — il
-- suffirait de déclarer le chiffre affiché. C'est la seule mécanique de ce
-- module qui détecte un écart de caisse, et elle ne vaut que par cet ordre :
-- compter d'abord, comparer ensuite.
--
--   * X = contrôle intermédiaire (passage de relais, contrôle de milieu de
--     service). Ne clôt rien : la période continue de courir.
--   * Z = clôture de journée. La période suivante repart de cette date — c'est
--     ce qui « remet le compteur à zéro ».
--
-- COLONNES AJOUTÉES vs la spec, et pourquoi :
--   * `period_start` — sans elle, impossible de savoir sur quelle plage porte
--     un écart, ni de recalculer un rapport a posteriori. Un écart sans période
--     n'est pas auditable.
--   * `opening_float` — le fond de caisse présent AVANT le premier encaissement.
--     Sans lui, l'écart d'une caisse qui démarre avec 20 000 F de monnaie est
--     faux de 20 000 F à chaque clôture, tous les jours.
--   * `cashier_name` — un `cashier_id` (UUID auth) ne parle à personne trois
--     semaines plus tard. Libellé figé à la clôture, comme `losses.declared_by`.
--   * `note` — le caissier explique un écart connu (« billet rendu en trop à
--     midi ») au moment où il s'en souvient.
--
-- `variance` est STOCKÉE plutôt que calculée à la lecture : c'est un constat
-- daté. Recalculer `declared − system` des mois plus tard donnerait un autre
-- chiffre si la définition du total système évolue — et effacerait l'écart
-- réellement constaté ce soir-là.
--
-- Conventions (alignées sur hotfix_137 / _140 / _145 / _146) : PK TEXT `cc_` +
-- microsecondes générée côté client (offline-first), montants INTEGER (FCFA),
-- RLS membres, Realtime.
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

CREATE TABLE IF NOT EXISTS public.cash_closures (
  id             TEXT PRIMARY KEY,
  shop_id        TEXT NOT NULL
                   REFERENCES public.shops(id) ON DELETE CASCADE,
  -- Qui a compté. Ref logique vers auth.users (pas de FK : un compte supprimé
  -- ne doit pas effacer l'historique des contrôles de caisse).
  cashier_id     TEXT,
  cashier_name   TEXT,
  closure_type   TEXT    NOT NULL DEFAULT 'X'
                   CHECK (closure_type IN ('X','Z')),
  -- Espèces comptées dans le tiroir, saisies À L'AVEUGLE.
  declared_cash  INTEGER NOT NULL,
  -- Espèces attendues : fond de caisse + encaissements espèces de la période.
  system_cash    INTEGER NOT NULL,
  -- declared_cash − system_cash. Négatif = manquant, positif = excédent.
  variance       INTEGER NOT NULL,
  opening_float  INTEGER NOT NULL DEFAULT 0,
  period_start   TIMESTAMPTZ,
  note           TEXT,
  schema_version INTEGER,
  closed_at      TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS cash_closures_shop_idx
  ON public.cash_closures(shop_id, closed_at DESC);
-- Retrouver la dernière clôture Z : c'est elle qui borne la période courante,
-- donc elle est lue à chaque ouverture de l'écran.
CREATE INDEX IF NOT EXISTS cash_closures_z_idx
  ON public.cash_closures(shop_id, closed_at DESC)
  WHERE closure_type = 'Z';

-- ── RLS : membres / owner / super-admin (lecture + écriture) ───────────────
ALTER TABLE public.cash_closures ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS cash_closures_members ON public.cash_closures;
CREATE POLICY cash_closures_members
  ON public.cash_closures
  FOR ALL TO authenticated
  USING      (public._is_shop_member(shop_id))
  WITH CHECK (public._is_shop_member(shop_id));

-- ── Realtime : le gérant voit l'écart depuis son téléphone, sans attendre ──
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
     WHERE pubname = 'supabase_realtime'
       AND schemaname = 'public'
       AND tablename  = 'cash_closures'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.cash_closures;
  END IF;
END $$;

-- ── Vérification ───────────────────────────────────────────────────────────
--   SELECT tablename, rowsecurity FROM pg_tables
--    WHERE schemaname='public' AND tablename='cash_closures';
--
--   -- Dernière clôture de journée :
--   SELECT closed_at, cashier_name, declared_cash, system_cash, variance
--     FROM public.cash_closures
--    WHERE shop_id='<shop>' AND closure_type='Z'
--    ORDER BY closed_at DESC LIMIT 1;
--
--   -- Caissiers dont les écarts s'accumulent (le vrai signal antifraude —
--   -- un écart isolé est une erreur, une somme d'écarts négatifs est un
--   -- comportement) :
--   SELECT cashier_name, count(*), sum(variance)
--     FROM public.cash_closures
--    WHERE shop_id='<shop>' AND closure_type='Z'
--    GROUP BY cashier_name ORDER BY sum(variance);
--
-- Fin — hotfix_147_cash_closures.sql
