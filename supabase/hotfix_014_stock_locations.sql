-- ═══════════════════════════════════════════════════════════════════════════
-- Fortress — Hotfix 014 : Stock multi-emplacement (Phase 1)
--
-- Ajoute :
--   1. Table stock_locations      — emplacements de stockage (shop, warehouse, partner)
--   2. Table stock_levels         — stock par (variante, emplacement)
--   3. Table stock_transfers      — transferts entre emplacements
--
-- Action :
--   1. FAIS UN BACKUP de tes données (Export CSV ou pg_dump) avant de lancer.
--   2. Coller ce fichier dans Supabase → SQL Editor → Run.
--   3. Le script est IDEMPOTENT : on peut le rejouer sans effet de bord.
--   4. Aucun ALTER/DROP sur les tables existantes. Tes produits, stocks,
--      ventes, etc. ne sont PAS modifiés.
-- ═══════════════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────────────
-- 1. Table stock_locations
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS stock_locations (
  id                  TEXT PRIMARY KEY,
  owner_id            TEXT NOT NULL,
  type                TEXT NOT NULL
                      CHECK (type IN ('shop', 'warehouse', 'partner')),
  name                TEXT NOT NULL,
  shop_id             TEXT REFERENCES shops(id) ON DELETE CASCADE,
  parent_warehouse_id TEXT REFERENCES stock_locations(id) ON DELETE SET NULL,
  address             TEXT,
  phone               TEXT,
  contact_name        TEXT,
  notes               TEXT,
  is_active           BOOLEAN NOT NULL DEFAULT true,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Un shop_id ne peut avoir qu'UNE seule location de type 'shop' (unicité logique)
CREATE UNIQUE INDEX IF NOT EXISTS stock_locations_shop_unique
  ON stock_locations(shop_id)
  WHERE type = 'shop' AND shop_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS stock_locations_owner_idx ON stock_locations(owner_id);
CREATE INDEX IF NOT EXISTS stock_locations_type_idx  ON stock_locations(type);

ALTER TABLE stock_locations ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS stock_locations_owner_access ON stock_locations;
CREATE POLICY stock_locations_owner_access ON stock_locations
  FOR ALL USING (
    -- Le propriétaire direct
    owner_id = auth.uid()::text
    OR
    -- Les membres des boutiques rattachées (type = 'shop' → scope via shop_memberships)
    (shop_id IS NOT NULL AND shop_id IN (
      SELECT shop_id FROM shop_memberships WHERE user_id = auth.uid()::text
    ))
  );

-- ───────────────────────────────────────────────────────────────────────────
-- 2. Table stock_levels
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS stock_levels (
  id                TEXT PRIMARY KEY,
  variant_id        TEXT NOT NULL,
  location_id       TEXT NOT NULL REFERENCES stock_locations(id) ON DELETE CASCADE,
  shop_id           TEXT REFERENCES shops(id) ON DELETE CASCADE,
  stock_available   INTEGER NOT NULL DEFAULT 0,
  stock_physical    INTEGER NOT NULL DEFAULT 0,
  stock_blocked     INTEGER NOT NULL DEFAULT 0,
  stock_ordered     INTEGER NOT NULL DEFAULT 0,
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(variant_id, location_id)
);

CREATE INDEX IF NOT EXISTS stock_levels_location_idx ON stock_levels(location_id);
CREATE INDEX IF NOT EXISTS stock_levels_variant_idx  ON stock_levels(variant_id);
CREATE INDEX IF NOT EXISTS stock_levels_shop_idx     ON stock_levels(shop_id);

ALTER TABLE stock_levels ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS stock_levels_access ON stock_levels;
CREATE POLICY stock_levels_access ON stock_levels
  FOR ALL USING (
    -- Accès si l'utilisateur est owner ou membre d'une boutique liée à la location
    location_id IN (
      SELECT id FROM stock_locations
      WHERE owner_id = auth.uid()::text
         OR (shop_id IS NOT NULL AND shop_id IN (
              SELECT shop_id FROM shop_memberships
              WHERE user_id = auth.uid()::text
            ))
    )
  );

-- ───────────────────────────────────────────────────────────────────────────
-- 3. Table stock_transfers
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS stock_transfers (
  id                TEXT PRIMARY KEY,
  owner_id          TEXT NOT NULL,
  from_location_id  TEXT NOT NULL REFERENCES stock_locations(id) ON DELETE RESTRICT,
  to_location_id    TEXT NOT NULL REFERENCES stock_locations(id) ON DELETE RESTRICT,
  status            TEXT NOT NULL DEFAULT 'draft'
                    CHECK (status IN ('draft','shipped','received','cancelled')),
  lines             JSONB NOT NULL DEFAULT '[]'::jsonb,
  notes             TEXT,
  created_by        TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  shipped_at        TIMESTAMPTZ,
  received_at       TIMESTAMPTZ,
  cancelled_at      TIMESTAMPTZ,
  CHECK (from_location_id <> to_location_id)
);

CREATE INDEX IF NOT EXISTS stock_transfers_owner_idx      ON stock_transfers(owner_id);
CREATE INDEX IF NOT EXISTS stock_transfers_from_idx       ON stock_transfers(from_location_id);
CREATE INDEX IF NOT EXISTS stock_transfers_to_idx         ON stock_transfers(to_location_id);
CREATE INDEX IF NOT EXISTS stock_transfers_status_idx     ON stock_transfers(status);
CREATE INDEX IF NOT EXISTS stock_transfers_created_at_idx ON stock_transfers(created_at DESC);

ALTER TABLE stock_transfers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS stock_transfers_owner_access ON stock_transfers;
CREATE POLICY stock_transfers_owner_access ON stock_transfers
  FOR ALL USING (
    owner_id = auth.uid()::text
    OR
    -- Un membre des boutiques source/destination peut voir/agir
    from_location_id IN (
      SELECT id FROM stock_locations WHERE shop_id IN (
        SELECT shop_id FROM shop_memberships WHERE user_id = auth.uid()::text
      )
    )
    OR
    to_location_id IN (
      SELECT id FROM stock_locations WHERE shop_id IN (
        SELECT shop_id FROM shop_memberships WHERE user_id = auth.uid()::text
      )
    )
  );

-- ═══════════════════════════════════════════════════════════════════════════
-- Fin — hotfix_014_stock_locations.sql
-- Les 3 nouvelles tables sont prêtes, vides. La migration des stocks existants
-- sera effectuée côté application au prochain démarrage de l'app
-- (voir AppDatabase._migrateStocksToLocationsV1 — Tâche 13).
-- ═══════════════════════════════════════════════════════════════════════════
