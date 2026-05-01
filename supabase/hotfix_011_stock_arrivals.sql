-- ═══════════════════════════════════════════════════════════════════════════
-- Fortress — Hotfix 011 : Table stock_arrivals
--
-- Enregistre chaque arrivée en stock par variante avec statut et cause.
--
-- Action : coller dans Supabase → SQL Editor → Run.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS stock_arrivals (
  id                TEXT PRIMARY KEY,
  variant_id        TEXT,
  product_id        TEXT REFERENCES products(id) ON DELETE SET NULL,
  shop_id           TEXT NOT NULL REFERENCES shops(id) ON DELETE CASCADE,
  quantity          INT NOT NULL DEFAULT 0,
  status            TEXT NOT NULL DEFAULT 'available'
                    CHECK (status IN ('available','damaged','defective','to_inspect')),
  cause             TEXT NOT NULL DEFAULT 'direct_restock'
                    CHECK (cause IN (
                      'supplier_delivery',
                      'supplier_order',
                      'client_return',
                      'shop_transfer',
                      'direct_restock',
                      'other'
                    )),
  related_order_id  TEXT,
  note              TEXT,
  created_by        TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE stock_arrivals ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS sa_shop_access ON stock_arrivals;
CREATE POLICY sa_shop_access ON stock_arrivals
  FOR ALL USING (
    shop_id::text IN (
      SELECT shop_id FROM shop_memberships WHERE user_id = auth.uid()::text
    )
  );

CREATE INDEX IF NOT EXISTS idx_stock_arrivals_shop ON stock_arrivals(shop_id);
CREATE INDEX IF NOT EXISTS idx_stock_arrivals_variant ON stock_arrivals(variant_id);
CREATE INDEX IF NOT EXISTS idx_stock_arrivals_product ON stock_arrivals(product_id);
