-- hotfix_146_bottle_deposits.sql
-- ═════════════════════════════════════════════════════════════════════════
-- CONSIGNES BOUTEILLES (Lot B du cahier des charges restaurant).
--
-- `bottle_deposits` — les emballages consignés remis à un client : combien de
-- bouteilles, à quel montant l'unité, combien sont revenues.
--
-- Pourquoi une table et pas une simple ligne de frais sur la commande : une
-- consigne SURVIT à la commande. Le client paie son casier aujourd'hui et
-- rapporte les bouteilles la semaine prochaine, souvent sans son ticket. Il
-- faut donc une liste des consignes ouvertes, interrogeable par boutique et
-- indépendante du cycle de vie de l'addition (qui, elle, est close et payée).
--
-- Le MONTANT, lui, reste facturé via les frais de la commande (`orders.fees`) :
-- c'est ce qui le fait entrer dans le total encaissé sans dupliquer une
-- mécanique de facturation. Cette table porte le SUIVI des retours.
--
-- ÉCARTS ASSUMÉS vs la spec :
--   * `product_id` NULLABLE + colonne `label` : un contenant consigné n'est pas
--     toujours un produit du catalogue (« casier 12 × 65 cl » se consigne, ne
--     se vend pas), et un produit supprimé ne doit pas rendre la consigne
--     illisible six mois plus tard. Le libellé est figé à la création.
--   * statut `'lost'` ajouté au CHECK : une consigne dont les bouteilles ne
--     reviendront jamais n'est ni « en attente » ni « rendue ». La marquer
--     rendue mentirait sur le stock d'emballages ; la laisser en attente
--     ferait enfler indéfiniment la liste des retours à réclamer. Elle
--     déclenche une perte `consigne_perdue` (cf. §2).
--
-- Conventions (alignées sur hotfix_137 / _140 / _141 / _145) : PK TEXT `bd_`
-- + microsecondes générée côté client (offline-first), PAS de FK vers `orders`
-- ni `products` (l'ordre des upserts n'est pas garanti hors ligne), RLS
-- membres, Realtime.
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
-- 1. CONSIGNES
-- ══════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.bottle_deposits (
  id                TEXT PRIMARY KEY,
  shop_id           TEXT NOT NULL
                      REFERENCES public.shops(id) ON DELETE CASCADE,
  order_id          TEXT,            -- ref logique vers orders (pas de FK)
  product_id        TEXT,            -- ref logique vers products (pas de FK)
  -- Libellé figé à la création : ce que le personnel lira dans la liste des
  -- retours, même si le produit a changé de nom ou disparu.
  label             TEXT    NOT NULL DEFAULT 'Consigne',
  quantity          INTEGER NOT NULL,
  deposit_per_unit  INTEGER NOT NULL,
  returned_quantity INTEGER NOT NULL DEFAULT 0,
  status            TEXT    NOT NULL DEFAULT 'pending'
                      CHECK (status IN (
                        'pending','partially_returned','fully_returned','lost')),
  -- Repère humain du débiteur (table, compte, nom du client). Une consigne se
  -- réclame à une personne, pas à un identifiant de commande.
  holder            TEXT,
  schema_version    INTEGER,
  created_at        TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS bottle_deposits_shop_idx
  ON public.bottle_deposits(shop_id);
CREATE INDEX IF NOT EXISTS bottle_deposits_order_idx
  ON public.bottle_deposits(order_id);
-- Les consignes ENCORE DUES : la seule liste que le personnel consulte
-- quotidiennement. Index partiel → il ne grossit pas avec l'historique.
CREATE INDEX IF NOT EXISTS bottle_deposits_open_idx
  ON public.bottle_deposits(shop_id, created_at)
  WHERE status IN ('pending','partially_returned');

-- ══════════════════════════════════════════════════════════════════════════
-- 2. PERTES — nouvelle catégorie « consigne perdue ».
-- ══════════════════════════════════════════════════════════════════════════
-- Le CHECK est remplacé (drop puis recreate) : Postgres ne sait pas étendre
-- une contrainte existante. Aucune ligne existante n'est invalidée — la
-- nouvelle liste est un sur-ensemble de celle de hotfix_141.
ALTER TABLE public.losses
  DROP CONSTRAINT IF EXISTS losses_category_check;

ALTER TABLE public.losses
  ADD CONSTRAINT losses_category_check CHECK (category IN (
    'casse','reste_invendu','plat_mal_fait',
    'non_paye','materiel_endommage','ecart_inventaire',
    'consigne_perdue','autre'));

COMMENT ON COLUMN public.losses.category IS
  'casse · reste_invendu · plat_mal_fait · non_paye · materiel_endommage · '
  'ecart_inventaire (hotfix_141) · consigne_perdue (hotfix_146) · autre.';

-- ── RLS : membres / owner / super-admin (lecture + écriture) ───────────────
ALTER TABLE public.bottle_deposits ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS bottle_deposits_members ON public.bottle_deposits;
CREATE POLICY bottle_deposits_members
  ON public.bottle_deposits
  FOR ALL TO authenticated
  USING      (public._is_shop_member(shop_id))
  WITH CHECK (public._is_shop_member(shop_id));

-- ── Realtime : le comptoir enregistre, la caisse voit le retour ────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
     WHERE pubname = 'supabase_realtime'
       AND schemaname = 'public'
       AND tablename  = 'bottle_deposits'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.bottle_deposits;
  END IF;
END $$;

-- ── Vérification ───────────────────────────────────────────────────────────
--   SELECT tablename, rowsecurity FROM pg_tables
--    WHERE schemaname='public' AND tablename='bottle_deposits';
--   SELECT pg_get_constraintdef(oid) FROM pg_constraint
--    WHERE conname='losses_category_check';
--
--   -- Emballages encore dehors, et l'argent qu'ils représentent :
--   SELECT sum(quantity - returned_quantity)                       AS bouteilles,
--          sum((quantity - returned_quantity) * deposit_per_unit)  AS montant
--     FROM public.bottle_deposits
--    WHERE shop_id='<shop>' AND status IN ('pending','partially_returned');
--
-- Fin — hotfix_146_bottle_deposits.sql
