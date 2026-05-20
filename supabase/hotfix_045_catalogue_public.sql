-- hotfix_045_catalogue_public.sql
--
-- Ouvre l'accès en lecture ANONYME aux tables `shops` et `products` pour
-- alimenter la page publique `/catalogue/:shopId` (vitrine accessible sans
-- authentification depuis https://fortress-pos.web.app/#/catalogue/<id>).
--
-- Filtres appliqués au niveau RLS :
--   - shops    : `is_active = true` (boutiques fermées non listées)
--   - products : `is_visible_web = true AND is_active = true`
--
-- Les politiques utilisent `TO anon` UNIQUEMENT — les utilisateurs
-- authentifiés conservent leurs accès via les policies existantes
-- (`TO authenticated`). PostgreSQL combine les policies SELECT par OR,
-- donc cette migration n'affecte pas la sécurité des accès connectés.
--
-- Idempotent : DROP IF EXISTS avant CREATE. Sûr à ré-exécuter.

-- ─── shops : SELECT public minimal ─────────────────────────────────────────
DROP POLICY IF EXISTS "shops_anon_read_active" ON public.shops;
CREATE POLICY "shops_anon_read_active" ON public.shops
  FOR SELECT
  TO anon
  USING (is_active = true);

-- ─── products : SELECT public uniquement si visible web ────────────────────
DROP POLICY IF EXISTS "products_anon_read_visible_web" ON public.products;
CREATE POLICY "products_anon_read_visible_web" ON public.products
  FOR SELECT
  TO anon
  USING (
    is_visible_web = true
    AND is_active  = true
    AND store_id IN (SELECT id::text FROM public.shops WHERE is_active = true)
  );
