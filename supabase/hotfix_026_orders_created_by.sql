-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_026_orders_created_by.sql
--
-- Ajoute `created_by_user_id` à la table orders pour permettre le filtre
-- dashboard "vendeur ne voit que ses ventes" (étape 5F hotfix_024).
--
-- - Nullable : les ventes historiques restent valides (afficheées seulement
--   aux admins/owners qui voient tout).
-- - Pas de FK stricte vers auth.users : les casts text/uuid varient selon
--   les schemas legacy ; on stocke l'uuid en TEXT.
-- ════════════════════════════════════════════════════════════════════════════

ALTER TABLE orders
  ADD COLUMN IF NOT EXISTS created_by_user_id TEXT;

CREATE INDEX IF NOT EXISTS idx_orders_created_by
  ON orders(shop_id, created_by_user_id);
