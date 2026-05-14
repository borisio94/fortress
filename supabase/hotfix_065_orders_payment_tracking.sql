-- ═══════════════════════════════════════════════════════════════════════════
-- Fortress — Hotfix 065 : Suivi paiement partiel sur les commandes
--
-- Ajoute 2 colonnes à la table `orders` pour distinguer paiement total /
-- partiel / non payé. Utilisé par le tunnel acompte boutique + livraison
-- partenaire : le partenaire ne doit verser à la boutique que le SOLDE
-- effectivement encaissé (= total − acompte déjà payé à la boutique),
-- pas le total brut.
--
-- Colonnes :
--   • amount_paid     NUMERIC(12,2) DEFAULT 0  — somme effectivement encaissée
--   • payment_status  TEXT          DEFAULT 'unpaid' — workflow paiement,
--     orthogonal au `status` (workflow commande).
--
-- Valeurs payment_status :
--   • unpaid    → rien d'encaissé. Par défaut pour les nouvelles commandes
--                 sans acompte.
--   • partial   → acompte versé, solde restant. amount_paid < total.
--   • paid      → totalement encaissée. status passe à 'completed' à la
--                 livraison + finalisation, ce flag confirme l'encaissement.
--   • refunded  → remboursée. Aligné sur status='refunded' mais peut
--                 diverger (remboursement partiel à terme).
--
-- Backfill : les commandes historiques `status='completed'` sont marquées
-- 'paid' (l'app présume payé pour les ventes finalisées avant ce hotfix).
-- `amount_paid` reste à 0 par défaut — la source de vérité pour ces
-- commandes héritées est `payment_status` seul. Pour les nouvelles
-- commandes, `amount_paid` reflète l'encaissement réel et permet
-- d'afficher « Reste à payer ».
--
-- Action :
--   1. Coller dans Supabase → SQL Editor → Run.
--   2. Idempotent : DO $$ ... IF NOT EXISTS sur chaque ALTER.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. Ajout colonne amount_paid ──────────────────────────────────────────
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'orders' AND column_name = 'amount_paid'
  ) THEN
    ALTER TABLE orders
      ADD COLUMN amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0;
  END IF;
END $$;

-- ── 2. Ajout colonne payment_status ───────────────────────────────────────
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'orders' AND column_name = 'payment_status'
  ) THEN
    ALTER TABLE orders
      ADD COLUMN payment_status TEXT NOT NULL DEFAULT 'unpaid';
  END IF;
END $$;

-- ── 3. CHECK constraint sur payment_status (idempotente) ─────────────────
ALTER TABLE orders DROP CONSTRAINT IF EXISTS orders_payment_status_check;
ALTER TABLE orders ADD CONSTRAINT orders_payment_status_check CHECK (
  payment_status IN ('unpaid', 'partial', 'paid', 'refunded')
);

-- ── 4. Backfill : commandes historiques `completed` → 'paid' ─────────────
-- Source de vérité pour le legacy : on présume que tout completed était payé
-- en totalité avant ce hotfix. amount_paid reste à 0 (informationnel) — la
-- logique Dart traite `payment_status = 'paid'` comme « rien à recouvrer ».
UPDATE orders
   SET payment_status = 'paid'
 WHERE status = 'completed'
   AND payment_status = 'unpaid';

-- Idem refunded : aligner payment_status sur status pour cohérence.
UPDATE orders
   SET payment_status = 'refunded'
 WHERE status = 'refunded'
   AND payment_status <> 'refunded';

-- ── 5. Index pour les filtres rapports ───────────────────────────────────
CREATE INDEX IF NOT EXISTS orders_payment_status_idx
  ON orders(payment_status);

-- Index partiel pour "commandes en partial" — souvent demandé en dashboard.
CREATE INDEX IF NOT EXISTS orders_partial_idx
  ON orders(shop_id, payment_status)
  WHERE payment_status = 'partial';

-- ═══════════════════════════════════════════════════════════════════════════
-- Fin — hotfix_065_orders_payment_tracking.sql
-- ═══════════════════════════════════════════════════════════════════════════
