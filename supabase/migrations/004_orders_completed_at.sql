-- ═══════════════════════════════════════════════════════════════════════════
-- Fortress — Migration 004 : ajouter completed_at à orders
-- Stocke l'instant où une commande passe au statut "completed" pour que le
-- dashboard et les rapports agrègent sur la date réelle d'encaissement
-- (et non sur la date de création de la commande programmée).
-- Idempotent grâce à IF NOT EXISTS.
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE orders ADD COLUMN IF NOT EXISTS completed_at TIMESTAMPTZ;
CREATE INDEX IF NOT EXISTS orders_completed_at_idx
  ON orders(completed_at DESC) WHERE completed_at IS NOT NULL;
