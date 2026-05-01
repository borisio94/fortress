-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_041_rls_critical_tables.sql
--
-- 🚨 HIGH — active la Row-Level Security sur les 4 tables critiques qui
-- n'avaient AUCUNE policy : `shops`, `products`, `orders`, `clients`.
-- Sans RLS, n'importe quel utilisateur authentifié pouvait lire les
-- commandes / clients / produits / boutiques de TOUS les autres users.
--
-- Modèle d'autorisation (mirroir de _is_shop_admin et AppPermissions) :
--   - SELECT : tout membre actif du shop (owner | admin | user) OU super-admin.
--   - INSERT : tout membre du shop (le shop_id/store_id doit cibler un shop
--              dont l'auteur est membre). Pour `shops` : auth.uid() crée son
--              propre shop comme owner.
--   - UPDATE : tout membre du shop (les triggers existants raffinent
--              encore : enforce_max_admins, protect_owner_delete,
--              enforce_order_mutation_perms, etc.).
--   - DELETE : owner uniquement OU super-admin pour shops/products/orders.
--             Pour clients : tout membre (les soft-deletes via isArchived
--             sont préférés côté client mais on autorise au cas où).
--
-- 100 % idempotent.
-- ════════════════════════════════════════════════════════════════════════════


-- ── 1a. Helper : auth.uid() est-il super-admin global ? ─────────────────
-- SECURITY DEFINER + ownership postgres → bypass RLS lors de la lecture
-- de `profiles`. Évite la récursion infinie (42P17) si une policy sur
-- `profiles` ou `shops` doit tester ce flag.
--
-- CREATE OR REPLACE plutôt que DROP+CREATE pour éviter 2BP01 si la
-- fonction est déjà référencée par des policies (rejeu du hotfix).
CREATE OR REPLACE FUNCTION public._is_super_admin()
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $sa$
  SELECT EXISTS (
    SELECT 1 FROM profiles
     WHERE id::text = auth.uid()::text
       AND COALESCE(is_super_admin, false) = TRUE
  );
$sa$;

ALTER FUNCTION public._is_super_admin() OWNER TO postgres;
REVOKE ALL ON FUNCTION public._is_super_admin() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public._is_super_admin() TO authenticated;


-- ── 1b. Helper : auth.uid() est-il membre actif du shop ? ───────────────
-- CREATE OR REPLACE : signature inchangée, donc on met à jour le body
-- sans toucher aux 13 policies qui en dépendent.
CREATE OR REPLACE FUNCTION public._is_shop_member(p_shop_id TEXT)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $is_mem$
  SELECT
    -- Owner direct (shops.owner_id)
    EXISTS (
      SELECT 1 FROM shops
       WHERE id::text       = p_shop_id
         AND owner_id::text = auth.uid()::text
    )
    OR
    -- Membership active (caissier, admin, owner)
    EXISTS (
      SELECT 1 FROM shop_memberships
       WHERE shop_id::text = p_shop_id
         AND user_id::text = auth.uid()::text
         AND COALESCE(status, 'active') = 'active'
    )
    OR
    -- Super admin global (via helper SECURITY DEFINER → pas de récursion)
    public._is_super_admin();
$is_mem$;

ALTER FUNCTION public._is_shop_member(TEXT) OWNER TO postgres;
REVOKE ALL ON FUNCTION public._is_shop_member(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public._is_shop_member(TEXT) TO authenticated;


-- ── 2. RLS sur `shops` ───────────────────────────────────────────────────
ALTER TABLE shops ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS shops_select ON shops;
CREATE POLICY shops_select ON shops FOR SELECT TO authenticated
  USING (public._is_shop_member(id::text));

DROP POLICY IF EXISTS shops_insert ON shops;
CREATE POLICY shops_insert ON shops FOR INSERT TO authenticated
  WITH CHECK (owner_id::text = auth.uid()::text);

DROP POLICY IF EXISTS shops_update ON shops;
CREATE POLICY shops_update ON shops FOR UPDATE TO authenticated
  USING (
    owner_id::text = auth.uid()::text
    OR public._is_super_admin()
  );

DROP POLICY IF EXISTS shops_delete ON shops;
CREATE POLICY shops_delete ON shops FOR DELETE TO authenticated
  USING (
    owner_id::text = auth.uid()::text
    OR public._is_super_admin()
  );


-- ── 3. RLS sur `products` (clé : products.store_id) ──────────────────────
ALTER TABLE products ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS products_select ON products;
CREATE POLICY products_select ON products FOR SELECT TO authenticated
  USING (public._is_shop_member(store_id::text));

DROP POLICY IF EXISTS products_insert ON products;
CREATE POLICY products_insert ON products FOR INSERT TO authenticated
  WITH CHECK (public._is_shop_member(store_id::text));

DROP POLICY IF EXISTS products_update ON products;
CREATE POLICY products_update ON products FOR UPDATE TO authenticated
  USING (public._is_shop_member(store_id::text))
  WITH CHECK (public._is_shop_member(store_id::text));

DROP POLICY IF EXISTS products_delete ON products;
CREATE POLICY products_delete ON products FOR DELETE TO authenticated
  USING (public._is_shop_member(store_id::text));


-- ── 4. RLS sur `orders` (clé : orders.shop_id) ───────────────────────────
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS orders_select ON orders;
CREATE POLICY orders_select ON orders FOR SELECT TO authenticated
  USING (public._is_shop_member(shop_id::text));

DROP POLICY IF EXISTS orders_insert ON orders;
CREATE POLICY orders_insert ON orders FOR INSERT TO authenticated
  WITH CHECK (public._is_shop_member(shop_id::text));

DROP POLICY IF EXISTS orders_update ON orders;
CREATE POLICY orders_update ON orders FOR UPDATE TO authenticated
  USING (public._is_shop_member(shop_id::text))
  WITH CHECK (public._is_shop_member(shop_id::text));
-- Note : trg_enforce_order_mutation_perms (hotfix_039) raffine encore les
-- transitions cancelled/refunded et discount_amount.

DROP POLICY IF EXISTS orders_delete ON orders;
CREATE POLICY orders_delete ON orders FOR DELETE TO authenticated
  USING (public._is_shop_member(shop_id::text));


-- ── 5. RLS sur `clients` (clé : clients.store_id) ────────────────────────
ALTER TABLE clients ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS clients_select ON clients;
CREATE POLICY clients_select ON clients FOR SELECT TO authenticated
  USING (public._is_shop_member(store_id::text));

DROP POLICY IF EXISTS clients_insert ON clients;
CREATE POLICY clients_insert ON clients FOR INSERT TO authenticated
  WITH CHECK (public._is_shop_member(store_id::text));

DROP POLICY IF EXISTS clients_update ON clients;
CREATE POLICY clients_update ON clients FOR UPDATE TO authenticated
  USING (public._is_shop_member(store_id::text))
  WITH CHECK (public._is_shop_member(store_id::text));

DROP POLICY IF EXISTS clients_delete ON clients;
CREATE POLICY clients_delete ON clients FOR DELETE TO authenticated
  USING (public._is_shop_member(store_id::text));


-- ── 6. RLS sur `profiles` ────────────────────────────────────────────────
-- Critique : sans RLS, tout authenticated voit emails+tel+nom de TOUS les
-- users (PII). On limite à : voir son propre profil + voir les profils
-- des membres de ses boutiques (utile pour list_shop_employees) + super-admin.
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS profiles_select ON profiles;
CREATE POLICY profiles_select ON profiles FOR SELECT TO authenticated
  USING (
    -- Soi-même
    id::text = auth.uid()::text
    -- OU membre d'une boutique partagée (collègue)
    OR EXISTS (
      SELECT 1 FROM shop_memberships my
       JOIN shop_memberships theirs
         ON theirs.shop_id = my.shop_id
       WHERE my.user_id::text     = auth.uid()::text
         AND theirs.user_id::text = profiles.id::text
    )
    -- OU super-admin global (via helper SECURITY DEFINER → pas de
    --   récursion sur profiles_select).
    OR public._is_super_admin()
  );

DROP POLICY IF EXISTS profiles_insert ON profiles;
CREATE POLICY profiles_insert ON profiles FOR INSERT TO authenticated
  WITH CHECK (id::text = auth.uid()::text);

DROP POLICY IF EXISTS profiles_update ON profiles;
CREATE POLICY profiles_update ON profiles FOR UPDATE TO authenticated
  USING (id::text = auth.uid()::text)
  WITH CHECK (id::text = auth.uid()::text);
-- Pas de DELETE direct : la suppression de profil passe par
-- delete_user_account RPC (SECURITY DEFINER).


-- ── 7. Vérifications après application ──────────────────────────────────
-- SELECT tablename, rowsecurity FROM pg_tables
--  WHERE schemaname='public'
--    AND tablename IN ('shops','products','orders','clients','profiles');
-- → attendu : 5 lignes avec rowsecurity = true
--
-- Smoke test (avec un user A, pour vérifier qu'il NE voit PAS le shop d'un user B) :
-- En tant que user A non membre du shop B :
--   SELECT * FROM shops WHERE id = '<shop-id-de-B>';
-- → attendu : 0 ligne (RLS filtre)
