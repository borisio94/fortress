-- ═══════════════════════════════════════════════════════════════════════════
-- Fortress — Hotfix 015 : Mode de livraison sur les commandes
--
-- Ajoute 3 colonnes nullable à la table `orders` :
--   - delivery_mode         : 'pickup' | 'in_house' | 'partner'
--   - delivery_location_id  : id du StockLocation partenaire (si partner)
--   - delivery_person_name  : nom du livreur/contact (texte libre)
--
-- Action :
--   1. Coller ce fichier dans Supabase → SQL Editor → Run.
--   2. Script idempotent (peut être rejoué sans effet de bord).
--   3. Colonnes additives, les commandes existantes ne sont pas modifiées
--      (elles auront delivery_mode = NULL = "non classé").
-- ═══════════════════════════════════════════════════════════════════════════

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'orders' AND column_name = 'delivery_mode'
  ) THEN
    ALTER TABLE orders ADD COLUMN delivery_mode TEXT;
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'orders' AND column_name = 'delivery_location_id'
  ) THEN
    ALTER TABLE orders ADD COLUMN delivery_location_id TEXT;
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'orders' AND column_name = 'delivery_person_name'
  ) THEN
    ALTER TABLE orders ADD COLUMN delivery_person_name TEXT;
  END IF;
END $$;

-- Contrainte CHECK sur delivery_mode (idempotente)
ALTER TABLE orders DROP CONSTRAINT IF EXISTS orders_delivery_mode_check;
ALTER TABLE orders ADD CONSTRAINT orders_delivery_mode_check CHECK (
  delivery_mode IS NULL OR delivery_mode IN ('pickup', 'in_house', 'partner')
);

-- FK vers stock_locations (soft : ON DELETE SET NULL pour garder la commande
-- si le partenaire est supprimé)
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.table_constraints
    WHERE table_name = 'orders' AND constraint_name = 'orders_delivery_location_fk'
  ) THEN
    ALTER TABLE orders ADD CONSTRAINT orders_delivery_location_fk
      FOREIGN KEY (delivery_location_id) REFERENCES stock_locations(id)
      ON DELETE SET NULL;
  END IF;
END $$;

-- Index pour les stats par partenaire
CREATE INDEX IF NOT EXISTS orders_delivery_location_idx
  ON orders(delivery_location_id)
  WHERE delivery_location_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS orders_delivery_mode_idx
  ON orders(delivery_mode)
  WHERE delivery_mode IS NOT NULL;

-- ═══════════════════════════════════════════════════════════════════════════
-- Fin — hotfix_015_order_delivery_mode.sql
-- ═══════════════════════════════════════════════════════════════════════════
