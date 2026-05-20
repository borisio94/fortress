-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_061_stock_levels_rls_fix.sql
--
-- Corrige la RLS de `stock_levels` (et par cohérence `stock_locations`) qui
-- bloquait les INSERT avec erreur 42501 quand l'utilisateur connecté est
-- propriétaire de la boutique (`shops.owner_id`) mais que la `stock_location`
-- correspondante n'a pas son `owner_id` rempli (cas typique d'une boutique
-- créée avant hotfix_014, ou d'un partner_depot converti via hotfix_054).
--
-- Changements :
--   1. Élargit la condition d'accès pour inclure : owner direct de la shop
--      liée à la location (via `shops.owner_id`).
--   2. Ajoute `WITH CHECK` explicite identique à `USING` pour que les INSERT
--      soient évalués correctement (évite le piège silencieux où Postgres
--      réutilise USING mais que certaines évaluations échouent quand même).
--   3. Backfill : pour chaque `stock_location` orpheline d'`owner_id` mais
--      reliée à une `shops` avec owner_id, propage l'owner_id pour rendre
--      la policy passante même via la branche owner_id directe.
--
-- Idempotent : DROP POLICY IF EXISTS + CREATE POLICY.
-- À appliquer dans Supabase → SQL Editor → Run.
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ───────────────────────────────────────────────────────────────────────────
-- 0. Backfill defensif : remonter shops.owner_id vers stock_locations.owner_id
--    si manquant. Permet à la branche `stock_locations.owner_id = auth.uid()`
--    des policies de fonctionner même sur les locations créées sans owner.
-- ───────────────────────────────────────────────────────────────────────────
UPDATE stock_locations sl
   SET owner_id = s.owner_id
  FROM shops s
 WHERE sl.shop_id = s.id
   AND sl.owner_id IS NULL
   AND s.owner_id IS NOT NULL;

-- ───────────────────────────────────────────────────────────────────────────
-- 1. Policy stock_locations — élargie : owner direct OU shop_owner OU member
-- ───────────────────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS stock_locations_owner_access ON stock_locations;
CREATE POLICY stock_locations_owner_access ON stock_locations
  FOR ALL
  USING (
    owner_id = auth.uid()::text
    OR
    -- Owner de la boutique liée (cas d'une location type='shop' où
    -- owner_id de la location n'est pas rempli mais shops.owner_id l'est).
    (shop_id IS NOT NULL AND shop_id IN (
      SELECT id FROM shops WHERE owner_id = auth.uid()::text
    ))
    OR
    -- Membre de la boutique liée (employé / admin secondaire).
    (shop_id IS NOT NULL AND shop_id IN (
      SELECT shop_id FROM shop_memberships WHERE user_id = auth.uid()::text
    ))
  )
  WITH CHECK (
    owner_id = auth.uid()::text
    OR
    (shop_id IS NOT NULL AND shop_id IN (
      SELECT id FROM shops WHERE owner_id = auth.uid()::text
    ))
    OR
    (shop_id IS NOT NULL AND shop_id IN (
      SELECT shop_id FROM shop_memberships WHERE user_id = auth.uid()::text
    ))
  );

-- ───────────────────────────────────────────────────────────────────────────
-- 2. Policy stock_levels — élargie + WITH CHECK explicite
-- ───────────────────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS stock_levels_access ON stock_levels;
CREATE POLICY stock_levels_access ON stock_levels
  FOR ALL
  USING (
    location_id IN (
      SELECT sl.id
        FROM stock_locations sl
        LEFT JOIN shops s ON s.id = sl.shop_id
       WHERE sl.owner_id = auth.uid()::text
          OR (s.owner_id IS NOT NULL AND s.owner_id = auth.uid()::text)
          OR (sl.shop_id IS NOT NULL AND sl.shop_id IN (
                SELECT shop_id FROM shop_memberships
                 WHERE user_id = auth.uid()::text
              ))
    )
  )
  WITH CHECK (
    location_id IN (
      SELECT sl.id
        FROM stock_locations sl
        LEFT JOIN shops s ON s.id = sl.shop_id
       WHERE sl.owner_id = auth.uid()::text
          OR (s.owner_id IS NOT NULL AND s.owner_id = auth.uid()::text)
          OR (sl.shop_id IS NOT NULL AND sl.shop_id IN (
                SELECT shop_id FROM shop_memberships
                 WHERE user_id = auth.uid()::text
              ))
    )
  );

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- Vérification post-déploiement (à exécuter en read-only après le COMMIT) :
--
--   -- a) Combien de stock_locations te sont accessibles avec ton auth.uid() ?
--   SELECT count(*) FROM stock_locations;
--
--   -- b) Combien de stock_levels te sont accessibles ?
--   SELECT count(*) FROM stock_levels;
--
--   -- c) Test d'INSERT (remplace les XXX par des IDs valides) :
--   --    Doit réussir si ta shop a bien sa stock_location avec owner_id correct.
--   -- INSERT INTO stock_levels (id, variant_id, location_id, shop_id,
--   --   stock_available, stock_physical)
--   -- VALUES ('lvl_test_XXX', 'var_XXX', '<your_shop_loc_id>', '<your_shop_id>', 0, 0)
--   -- ON CONFLICT (variant_id, location_id) DO NOTHING;
-- ════════════════════════════════════════════════════════════════════════════
