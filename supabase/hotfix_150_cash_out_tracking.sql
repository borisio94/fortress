-- hotfix_150_cash_out_tracking.sql
-- ═════════════════════════════════════════════════════════════════════════
-- SORTIES D'ESPÈCES — ce qui quitte le tiroir autrement qu'en rendu monnaie.
--
-- La clôture de caisse aveugle (hotfix_147) ne déduisait que les dépenses
-- quotidiennes réglées en espèces. Trois autres sorties existent, et elles
-- apparaissaient toutes comme des MANQUANTS au comptage du soir :
--
--   1. une avance sur salaire versée du tiroir (cas dominant : le personnel
--      demande une avance en cours de mois, elle sort de la caisse) ;
--   2. un salaire payé en espèces à la fin du mois ;
--   3. une consigne d'emballages remboursée au client qui rapporte ses
--      bouteilles — l'argent qu'il avait versé lui est rendu.
--
-- Un caissier irréprochable se retrouvait accusé d'un manquant de 20 000 F
-- parce que le gérant avait pris cette somme dans le tiroir pour une avance.
-- C'est exactement le faux positif que la clôture aveugle doit éviter, sous
-- peine que le personnel cesse de s'en servir.
--
-- POURQUOI un drapeau et pas une hypothèse : toutes les avances ne sortent pas
-- du tiroir (virement, mobile money). Deviner « toujours espèces » aurait
-- remplacé un faux manquant par un faux excédent.
--
-- POURQUOI le remboursement de consigne passe par `daily_expenses` : c'est le
-- seul mécanisme déjà daté, synchronisé et rattaché au tiroir. Une catégorie
-- dédiée (`consigne_rendue`) le distingue des vraies charges — elle sort de la
-- caisse mais N'EST PAS une dépense d'exploitation : le client récupère son
-- propre argent. Elle est donc exclue du bilan P&L côté application.
--
-- 100 % idempotent (ré-exécutable sans effet de bord).
-- ═════════════════════════════════════════════════════════════════════════

-- ══════════════════════════════════════════════════════════════════════════
-- 1. AVANCES ET PAIES — payées en espèces ?
-- ══════════════════════════════════════════════════════════════════════════
ALTER TABLE public.salary_advances
  ADD COLUMN IF NOT EXISTS is_cash BOOLEAN NOT NULL DEFAULT true;

COMMENT ON COLUMN public.salary_advances.is_cash IS
  'Avance versée en espèces (défaut) → déduite du tiroir à la clôture de '
  'caisse. false = virement / mobile money, sans effet sur la caisse.';

ALTER TABLE public.payroll
  ADD COLUMN IF NOT EXISTS paid_cash BOOLEAN NOT NULL DEFAULT true;

COMMENT ON COLUMN public.payroll.paid_cash IS
  'Salaire versé en espèces (défaut) → déduit du tiroir à la date de paiement '
  '(paid_at). Sans effet tant que la fiche n''est pas marquée payée.';

-- ══════════════════════════════════════════════════════════════════════════
-- 2. DÉPENSES — nouvelle catégorie « consigne rendue ».
-- ══════════════════════════════════════════════════════════════════════════
-- Le CHECK est remplacé (drop puis recreate) : Postgres ne sait pas étendre
-- une contrainte existante. La nouvelle liste est un sur-ensemble de celle de
-- hotfix_149, aucune ligne existante n'est invalidée.
ALTER TABLE public.daily_expenses
  DROP CONSTRAINT IF EXISTS daily_expenses_category_check;

ALTER TABLE public.daily_expenses
  ADD CONSTRAINT daily_expenses_category_check CHECK (category IN (
    'achat_marche','electricite','gaz','eau','transport','entretien',
    'personnel','consigne_rendue','autre'));

COMMENT ON COLUMN public.daily_expenses.category IS
  'achat_marche (matières → food cost réel) · electricite · gaz · eau · '
  'transport · entretien · personnel (extras journaliers) · consigne_rendue '
  '(remboursement d''emballages : sort du tiroir mais N''EST PAS une charge, '
  'exclue du P&L) · autre.';

-- ── Vérification ───────────────────────────────────────────────────────────
--   SELECT column_name FROM information_schema.columns
--    WHERE (table_name='salary_advances' AND column_name='is_cash')
--       OR (table_name='payroll'         AND column_name='paid_cash');
--
--   SELECT pg_get_constraintdef(oid) FROM pg_constraint
--    WHERE conname='daily_expenses_category_check';
--
--   -- Tout ce qui est sorti du tiroir aujourd'hui :
--   SELECT 'dépenses' AS source, sum(amount) FROM public.daily_expenses
--    WHERE shop_id='<shop>' AND is_cash AND expense_date = CURRENT_DATE
--   UNION ALL
--   SELECT 'avances', sum(amount) FROM public.salary_advances
--    WHERE shop_id='<shop>' AND is_cash AND advance_date = CURRENT_DATE
--   UNION ALL
--   SELECT 'salaires', sum(net_salary) FROM public.payroll
--    WHERE shop_id='<shop>' AND paid_cash AND paid_at::date = CURRENT_DATE;
--
-- Fin — hotfix_150_cash_out_tracking.sql
