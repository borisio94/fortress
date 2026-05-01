-- ═══════════════════════════════════════════════════════════════════════════
-- Fortress — Hotfix 010 : Cycle de vie produit complet
--
-- Ajoute :
--   1. Colonne status sur products
--   2. Table suppliers (fournisseurs)
--   3. Table purchase_orders + purchase_order_items (commandes fournisseur)
--   4. Table stock_movements (mouvements de stock)
--   5. Table incidents (zone incidents)
--   6. Table receptions + reception_items (bons de réception)
--
-- Action : coller dans Supabase → SQL Editor → Run.
-- ═══════════════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────────────
-- 1. Colonne status sur products
-- ───────────────────────────────────────────────────────────────────────────
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'products' AND column_name = 'status'
  ) THEN
    ALTER TABLE products ADD COLUMN status TEXT NOT NULL DEFAULT 'available';
  END IF;
END $$;

-- Contrainte CHECK (idempotente)
ALTER TABLE products DROP CONSTRAINT IF EXISTS products_status_check;
ALTER TABLE products ADD CONSTRAINT products_status_check CHECK (
  status IN (
    'available',     -- En vente
    'discounted',    -- Prix réduit / promo
    'to_inspect',    -- À inspecter
    'damaged',       -- Endommagé
    'defective',     -- Défectueux
    'in_repair',     -- En réparation
    'scrapped',      -- Mis au rebut
    'returned',      -- Retourné
    'discontinued'   -- Arrêté / fin de vie
  )
);

-- ───────────────────────────────────────────────────────────────────────────
-- 2. Table suppliers
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS suppliers (
  id          TEXT PRIMARY KEY,
  shop_id     TEXT NOT NULL REFERENCES shops(id) ON DELETE CASCADE,
  name        TEXT NOT NULL,
  phone       TEXT,
  email       TEXT,
  address     TEXT,
  notes       TEXT,
  is_active   BOOLEAN NOT NULL DEFAULT true,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE suppliers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS suppliers_shop_access ON suppliers;
CREATE POLICY suppliers_shop_access ON suppliers
  FOR ALL USING (
    shop_id::text IN (
      SELECT shop_id FROM shop_memberships WHERE user_id = auth.uid()::text
    )
  );

-- ───────────────────────────────────────────────────────────────────────────
-- 3. Table purchase_orders + items
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS purchase_orders (
  id              TEXT PRIMARY KEY,
  shop_id         TEXT NOT NULL REFERENCES shops(id) ON DELETE CASCADE,
  supplier_id     TEXT REFERENCES suppliers(id) ON DELETE SET NULL,
  status          TEXT NOT NULL DEFAULT 'draft'
                  CHECK (status IN ('draft','sent','confirmed','in_transit',
                                    'received','cancelled')),
  notes           TEXT,
  expected_at     TIMESTAMPTZ,
  total_amount    DOUBLE PRECISION NOT NULL DEFAULT 0,
  created_by      TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE purchase_orders ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS po_shop_access ON purchase_orders;
CREATE POLICY po_shop_access ON purchase_orders
  FOR ALL USING (
    shop_id::text IN (
      SELECT shop_id FROM shop_memberships WHERE user_id = auth.uid()::text
    )
  );

CREATE TABLE IF NOT EXISTS purchase_order_items (
  id              TEXT PRIMARY KEY,
  order_id        TEXT NOT NULL REFERENCES purchase_orders(id) ON DELETE CASCADE,
  product_id      TEXT REFERENCES products(id) ON DELETE SET NULL,
  variant_id      TEXT,
  product_name    TEXT NOT NULL,
  quantity        INT NOT NULL DEFAULT 0,
  unit_price      DOUBLE PRECISION NOT NULL DEFAULT 0,
  received_qty    INT NOT NULL DEFAULT 0,
  damaged_qty     INT NOT NULL DEFAULT 0,
  notes           TEXT
);

-- ───────────────────────────────────────────────────────────────────────────
-- 4. Table stock_movements
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS stock_movements (
  id          TEXT PRIMARY KEY,
  shop_id     TEXT NOT NULL REFERENCES shops(id) ON DELETE CASCADE,
  product_id  TEXT REFERENCES products(id) ON DELETE SET NULL,
  variant_id  TEXT,
  type        TEXT NOT NULL CHECK (type IN (
    'entry',            -- Réception / ajout
    'sale',             -- Vente
    'adjustment',       -- Ajustement manuel
    'incident',         -- Incident (rebut, casse)
    'repair_cost',      -- Coût réparation
    'return_supplier',  -- Retour fournisseur
    'return_client',    -- Retour client
    'transfer',         -- Transfert entre boutiques
    'scrapped'          -- Mise au rebut
  )),
  quantity    INT NOT NULL,            -- positif = entrée, négatif = sortie
  unit_cost   DOUBLE PRECISION DEFAULT 0,
  reference   TEXT,                    -- ID commande, incident, etc.
  notes       TEXT,
  created_by  TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE stock_movements ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS sm_shop_access ON stock_movements;
CREATE POLICY sm_shop_access ON stock_movements
  FOR ALL USING (
    shop_id::text IN (
      SELECT shop_id FROM shop_memberships WHERE user_id = auth.uid()::text
    )
  );

-- ───────────────────────────────────────────────────────────────────────────
-- 5. Table incidents
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS incidents (
  id              TEXT PRIMARY KEY,
  shop_id         TEXT NOT NULL REFERENCES shops(id) ON DELETE CASCADE,
  product_id      TEXT REFERENCES products(id) ON DELETE SET NULL,
  variant_id      TEXT,
  product_name    TEXT NOT NULL,
  type            TEXT NOT NULL CHECK (type IN (
    'scrapped',          -- Mise au rebut
    'discounted',        -- Vente à prix réduit
    'in_repair',         -- Envoyé en réparation
    'return_supplier'    -- Retour fournisseur
  )),
  status          TEXT NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','in_progress','resolved','cancelled')),
  quantity        INT NOT NULL DEFAULT 1,
  repair_cost     DOUBLE PRECISION DEFAULT 0,
  sale_price      DOUBLE PRECISION DEFAULT 0,   -- prix réduit si type=discounted
  notes           TEXT,
  reception_id    TEXT,                          -- lié à un bon de réception
  resolved_at     TIMESTAMPTZ,
  created_by      TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE incidents ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS incidents_shop_access ON incidents;
CREATE POLICY incidents_shop_access ON incidents
  FOR ALL USING (
    shop_id::text IN (
      SELECT shop_id FROM shop_memberships WHERE user_id = auth.uid()::text
    )
  );

-- ───────────────────────────────────────────────────────────────────────────
-- 6. Table receptions + items
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS receptions (
  id              TEXT PRIMARY KEY,
  shop_id         TEXT NOT NULL REFERENCES shops(id) ON DELETE CASCADE,
  purchase_order_id TEXT REFERENCES purchase_orders(id) ON DELETE SET NULL,
  supplier_id     TEXT REFERENCES suppliers(id) ON DELETE SET NULL,
  status          TEXT NOT NULL DEFAULT 'draft'
                  CHECK (status IN ('draft','validated','cancelled')),
  notes           TEXT,
  created_by      TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE receptions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS receptions_shop_access ON receptions;
CREATE POLICY receptions_shop_access ON receptions
  FOR ALL USING (
    shop_id::text IN (
      SELECT shop_id FROM shop_memberships WHERE user_id = auth.uid()::text
    )
  );

CREATE TABLE IF NOT EXISTS reception_items (
  id              TEXT PRIMARY KEY,
  reception_id    TEXT NOT NULL REFERENCES receptions(id) ON DELETE CASCADE,
  product_id      TEXT REFERENCES products(id) ON DELETE SET NULL,
  variant_id      TEXT,
  product_name    TEXT NOT NULL,
  expected_qty    INT NOT NULL DEFAULT 0,
  received_qty    INT NOT NULL DEFAULT 0,
  damaged_qty     INT NOT NULL DEFAULT 0,
  defective_qty   INT NOT NULL DEFAULT 0,
  status          TEXT NOT NULL DEFAULT 'available'
                  CHECK (status IN ('available','damaged','defective','mixed')),
  notes           TEXT
);

-- ───────────────────────────────────────────────────────────────────────────
-- Index pour les requêtes fréquentes
-- ───────────────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_stock_movements_shop ON stock_movements(shop_id);
CREATE INDEX IF NOT EXISTS idx_stock_movements_product ON stock_movements(product_id);
CREATE INDEX IF NOT EXISTS idx_incidents_shop ON incidents(shop_id);
CREATE INDEX IF NOT EXISTS idx_incidents_status ON incidents(status);
CREATE INDEX IF NOT EXISTS idx_purchase_orders_shop ON purchase_orders(shop_id);
CREATE INDEX IF NOT EXISTS idx_receptions_shop ON receptions(shop_id);
CREATE INDEX IF NOT EXISTS idx_suppliers_shop ON suppliers(shop_id);
