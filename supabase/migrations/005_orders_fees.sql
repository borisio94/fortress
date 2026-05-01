-- ═══════════════════════════════════════════════════════════════════════════
-- Fortress — Migration 005 : ajouter fees à orders
-- Stocke les frais de commande (livraison, emballage…) sous forme JSONB :
--   [{id: '…', label: 'Livraison', amount: 1500}, …]
-- Idempotent grâce à IF NOT EXISTS.
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE orders ADD COLUMN IF NOT EXISTS fees JSONB NOT NULL DEFAULT '[]'::jsonb;
