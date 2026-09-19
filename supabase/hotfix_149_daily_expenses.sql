-- hotfix_149_daily_expenses.sql
-- ═════════════════════════════════════════════════════════════════════════
-- DÉPENSES QUOTIDIENNES (Lot E du cahier des charges restaurant).
--
-- `daily_expenses` — l'argent qui sort au jour le jour : achat au marché,
-- électricité, gaz, entretien, extras payés à la journée.
--
-- POURQUOI une table distincte de `fixed_charges` : une charge fixe est une
-- ÉCHÉANCE (un loyer qui revient tous les mois, qu'on peut anticiper et dont
-- on suit le paiement). Une dépense quotidienne est un FAIT (« 12 000 F de
-- poisson ce matin »), non prévisible, jamais récurrente. Les mélanger aurait
-- rendu la liste des échéances illisible et le rappel d'échéance inutile.
--
-- POURQUOI pas non plus la table `expenses` de l'e-commerce : elle porte un
-- `location_id` (boutique / partenaire) et des catégories pensées pour la
-- vente en ligne (marketing, expédition, stockage). Le module finances
-- restaurant a été volontairement coupé de cette logique.
--
-- C'EST CETTE TABLE QUI PORTE LE « FOOD COST RÉEL » : la somme des achats de
-- catégorie `market_purchase` sur une période, à comparer au coût matières
-- théorique déduit des fiches recettes. L'écart entre les deux, c'est le
-- gaspillage, le vol ou une fiche recette fausse — l'indicateur que le
-- restaurateur cherche.
--
-- ÉCART ASSUMÉ vs la spec : PAS de colonnes `expense_date` / `is_recurring`
-- ajoutées à `fixed_charges`. Cette table possède déjà `frequency`,
-- `next_due_date` et `paid_dates`, qui décrivent la récurrence de façon plus
-- fine et sont déjà câblées au reporting. Ajouter deux colonnes redondantes
-- aurait créé deux sources de vérité sur la même question.
--
-- Conventions (alignées sur hotfix_140 / _145 → _148) : PK TEXT `de_` +
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

CREATE TABLE IF NOT EXISTS public.daily_expenses (
  id             TEXT PRIMARY KEY,
  shop_id        TEXT NOT NULL
                   REFERENCES public.shops(id) ON DELETE CASCADE,
  description    TEXT    NOT NULL,
  amount         INTEGER NOT NULL,
  category       TEXT    NOT NULL DEFAULT 'autre'
                   CHECK (category IN (
                     'achat_marche',   -- matières premières (= food cost réel)
                     'electricite',
                     'gaz',
                     'eau',
                     'transport',
                     'entretien',
                     'personnel',      -- extras payés à la journée
                     'autre')),
  -- Qui a payé (nom libre) : dans un restaurant, l'argent du marché part
  -- souvent de la poche d'un employé qu'il faut rembourser.
  paid_by        TEXT,
  -- Payé en espèces ? Décide si la dépense sort du TIROIR — et donc si elle
  -- doit être déduite du total attendu à la clôture de caisse (hotfix_147).
  -- Sans ce drapeau, tout retrait d'espèces apparaissait comme un manquant.
  is_cash        BOOLEAN NOT NULL DEFAULT true,
  expense_date   DATE    NOT NULL DEFAULT CURRENT_DATE,
  schema_version INTEGER,
  created_at     TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS daily_expenses_shop_idx
  ON public.daily_expenses(shop_id, expense_date DESC);
-- Food cost réel d'une période : somme des achats de matières.
CREATE INDEX IF NOT EXISTS daily_expenses_market_idx
  ON public.daily_expenses(shop_id, expense_date)
  WHERE category = 'achat_marche';

COMMENT ON COLUMN public.daily_expenses.category IS
  'achat_marche (matières premières → food cost réel) · electricite · gaz · '
  'eau · transport · entretien · personnel (extras journaliers, PAS la paie '
  'mensuelle qui vit dans payroll) · autre.';

-- ── RLS : membres / owner / super-admin (lecture + écriture) ───────────────
ALTER TABLE public.daily_expenses ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS daily_expenses_members ON public.daily_expenses;
CREATE POLICY daily_expenses_members
  ON public.daily_expenses
  FOR ALL TO authenticated
  USING      (public._is_shop_member(shop_id))
  WITH CHECK (public._is_shop_member(shop_id));

-- ── Realtime : la dépense se saisit au marché, se lit à la caisse ──────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
     WHERE pubname = 'supabase_realtime'
       AND schemaname = 'public'
       AND tablename  = 'daily_expenses'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.daily_expenses;
  END IF;
END $$;

-- ── Vérification ───────────────────────────────────────────────────────────
--   SELECT tablename, rowsecurity FROM pg_tables
--    WHERE schemaname='public' AND tablename='daily_expenses';
--
--   -- Food cost réel du mois :
--   SELECT sum(amount) FROM public.daily_expenses
--    WHERE shop_id='<shop>' AND category='achat_marche'
--      AND expense_date >= date_trunc('month', CURRENT_DATE);
--
--   -- Sorties d'espèces du jour (déduites de la caisse attendue) :
--   SELECT sum(amount) FROM public.daily_expenses
--    WHERE shop_id='<shop>' AND is_cash AND expense_date = CURRENT_DATE;
--
--   -- Répartition des dépenses du mois :
--   SELECT category, sum(amount) FROM public.daily_expenses
--    WHERE shop_id='<shop>' AND expense_date >= date_trunc('month', CURRENT_DATE)
--    GROUP BY category ORDER BY sum(amount) DESC;
--
-- Fin — hotfix_149_daily_expenses.sql
