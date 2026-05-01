-- ═══════════════════════════════════════════════════════════════════════════
-- Fortress — Migration 006 : dépenses opérationnelles
-- Charges de la boutique non liées à une vente (abonnements, pub, loyer…).
-- Distinct de orders.fees (frais par commande, répartis sur les articles).
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS expenses (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id        TEXT NOT NULL REFERENCES shops(id) ON DELETE CASCADE,
  amount         DOUBLE PRECISION NOT NULL CHECK (amount >= 0),
  category       TEXT NOT NULL
                 CHECK (category IN ('subscription','marketing','shipping',
                                     'rent','utilities','salaries','supplies',
                                     'taxes','other')),
  label          TEXT NOT NULL,
  paid_at        TIMESTAMPTZ NOT NULL,
  payment_method TEXT DEFAULT 'cash',
  receipt_url    TEXT,
  notes          TEXT,
  created_by     UUID,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS expenses_shop_id_idx   ON expenses(shop_id);
CREATE INDEX IF NOT EXISTS expenses_paid_at_idx   ON expenses(paid_at DESC);
CREATE INDEX IF NOT EXISTS expenses_category_idx  ON expenses(category);
CREATE INDEX IF NOT EXISTS expenses_shop_paid_idx ON expenses(shop_id, paid_at DESC);

-- @@CHUNK@@

-- ── RLS : admin/propriétaire boutique + super admin ────────────────────────
ALTER TABLE expenses ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS expenses_super_admin_all ON expenses;
CREATE POLICY expenses_super_admin_all ON expenses
  FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles
             WHERE id = auth.uid() AND is_super_admin = true)
  );

DROP POLICY IF EXISTS expenses_shop_admin_all ON expenses;
CREATE POLICY expenses_shop_admin_all ON expenses
  FOR ALL USING (
    shop_id IN (
      SELECT shop_id FROM shop_memberships
       WHERE user_id::text = (auth.uid())::text AND role = 'admin'
    )
  );

DROP POLICY IF EXISTS expenses_shop_owner_all ON expenses;
CREATE POLICY expenses_shop_owner_all ON expenses
  FOR ALL USING (
    shop_id IN (SELECT id FROM shops WHERE owner_id::text = (auth.uid())::text)
  );

-- @@CHUNK@@

-- ── Realtime : publier la table pour les INSERT/UPDATE/DELETE ─────────────
DO $mig$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename  = 'expenses'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE expenses;
  END IF;
END $mig$;
