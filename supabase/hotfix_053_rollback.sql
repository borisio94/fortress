-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_053_rollback.sql
--
-- Annule entièrement la phase A. À ne lancer QUE si la migration a été
-- appliquée mais qu'on veut revenir en arrière (avant la phase B).
--
-- ⚠️ Ne pas lancer si du code applicatif (Flutter) lit déjà
-- `shops.kind` / `shops.parent_shop_id` / `product_visibility` — il
-- planterait. Faire un rollback du déploiement web AVANT.
-- ════════════════════════════════════════════════════════════════════════════

-- 1. Table product_visibility (CASCADE supprime aussi le trigger).
DROP TABLE IF EXISTS product_visibility CASCADE;
DROP FUNCTION IF EXISTS public._product_visibility_set_updated_at() CASCADE;

-- 2. shops.parent_shop_id
ALTER TABLE shops DROP CONSTRAINT IF EXISTS shops_parent_shop_fk;
DROP INDEX IF EXISTS shops_parent_shop_idx;
ALTER TABLE shops DROP COLUMN IF EXISTS parent_shop_id;

-- 3. shops.kind
ALTER TABLE shops DROP CONSTRAINT IF EXISTS shops_kind_check;
DROP INDEX IF EXISTS shops_kind_idx;
ALTER TABLE shops DROP COLUMN IF EXISTS kind;
