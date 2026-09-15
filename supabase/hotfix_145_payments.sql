-- hotfix_145_payments.sql
-- ═════════════════════════════════════════════════════════════════════════
-- RÈGLEMENTS D'UNE ADDITION (Lot A du cahier des charges restaurant).
--
-- `payments` — le DÉTAIL de l'encaissement : une ligne par règlement reçu.
-- Une addition de 12 000 réglée 5 000 en espèces + 7 000 en MTN Money produit
-- deux lignes. C'est ce qui manquait pour le paiement mixte, pour la
-- ventilation par opérateur (MTN vs Orange, indistinguables aujourd'hui) et
-- pour tracer le rendu monnaie.
--
-- POURQUOI UNE TABLE plutôt que d'étendre `orders.payment_method` :
--   * `PaymentMethod` (cash · mobileMoney · card · credit) est sérialisé dans
--     TOUTE l'application e-commerce — exports CSV, factures PDF, tableaux de
--     bord, tracking web public. Y ajouter 'mtn_money' ou 'mixed' aurait
--     changé le sens de données existantes pour des boutiques qui n'ont rien
--     demandé. La colonne reste donc la méthode DOMINANTE (celle du plus gros
--     montant), et le détail vit ici.
--   * Un règlement est un fait daté, pas un attribut de commande : plusieurs
--     par addition, chacun avec sa référence d'opérateur.
--
-- ÉCART ASSUMÉ vs la spec : PAS de valeur 'mixed' dans le CHECK. « Mixte »
-- n'est pas un mode de règlement, c'est la propriété d'une addition qui en
-- porte plusieurs — la déduire (`count(distinct method) > 1`) évite une valeur
-- qui pourrait contredire les lignes qu'elle résume.
--
-- Conventions (alignées sur hotfix_137 / _140 / _141) :
--   * PK TEXT `py_` + microsecondes, générée côté client → offline-first.
--   * PAS de FK vers `orders` : en offline-first l'ordre des upserts n'est pas
--     garanti, un règlement poussé avant sa commande violerait la FK et l'op
--     serait abandonnée après dix essais. Référence logique, intégrité tenue
--     côté application (les deux ids sont créés sur le même écran).
--   * `amount` en INTEGER (FCFA, pas de centimes) comme partout ailleurs.
--   * RLS membres + Realtime : sans elles, l'upsert renvoie « permission
--     denied » et l'encaissement d'une tablette n'atteint jamais la caisse.
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

CREATE TABLE IF NOT EXISTS public.payments (
  id             TEXT PRIMARY KEY,
  shop_id        TEXT NOT NULL
                   REFERENCES public.shops(id) ON DELETE CASCADE,
  order_id       TEXT    NOT NULL,   -- ref logique vers orders (pas de FK)
  method         TEXT    NOT NULL
                   CHECK (method IN (
                     'cash','mtn_money','orange_money','card','credit')),
  -- Montant IMPUTÉ à l'addition (hors rendu). La somme des `amount` d'une
  -- commande est donc directement ce qui a été encaissé — aucune soustraction
  -- à faire au moment de lire les chiffres.
  amount         INTEGER NOT NULL,
  -- Référence de transaction de l'opérateur (numéro MTN/OM, ticket carte).
  reference      TEXT,
  -- Rendu monnaie, espèces uniquement : `received − amount`. Conservé pour que
  -- la clôture de caisse retrouve le mouvement réel du tiroir.
  change_given   INTEGER DEFAULT 0,
  schema_version INTEGER,
  created_at     TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS payments_shop_idx  ON public.payments(shop_id);
CREATE INDEX IF NOT EXISTS payments_order_idx ON public.payments(order_id);
-- Ventilation par mode sur une période (rapport de caisse).
CREATE INDEX IF NOT EXISTS payments_shop_created_idx
  ON public.payments(shop_id, created_at);

-- ── RLS : membres / owner / super-admin (lecture + écriture) ───────────────
ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS payments_members ON public.payments;
CREATE POLICY payments_members
  ON public.payments
  FOR ALL TO authenticated
  USING      (public._is_shop_member(shop_id))
  WITH CHECK (public._is_shop_member(shop_id));

-- ── Realtime : la caisse et la tablette de salle doivent voir le même état ─
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
     WHERE pubname = 'supabase_realtime'
       AND schemaname = 'public'
       AND tablename  = 'payments'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.payments;
  END IF;
END $$;

-- ── Vérification ───────────────────────────────────────────────────────────
--   SELECT tablename, rowsecurity FROM pg_tables
--    WHERE schemaname='public' AND tablename='payments';
--   SELECT policyname FROM pg_policies
--    WHERE schemaname='public' AND tablename='payments';
--   SELECT tablename FROM pg_publication_tables
--    WHERE pubname='supabase_realtime' AND tablename='payments';
--
--   -- Ventilation d'une journée par mode de règlement :
--   SELECT method, count(*), sum(amount) FROM public.payments
--    WHERE shop_id='<shop>' AND created_at::date = CURRENT_DATE
--    GROUP BY method ORDER BY sum(amount) DESC;
--
--   -- Additions réglées en plusieurs fois (« mixte », déduit) :
--   SELECT order_id, count(DISTINCT method) FROM public.payments
--    GROUP BY order_id HAVING count(DISTINCT method) > 1;
--
-- Fin — hotfix_145_payments.sql
