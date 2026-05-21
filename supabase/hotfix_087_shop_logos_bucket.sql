-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_087_shop_logos_bucket.sql
--
-- Versionne les 3 changements appliqués manuellement en production pour
-- résoudre le bug d'upload logo (storage 403 / RLS) :
--
--   1. Ajout de la colonne `shops.logo_url` (TEXT, nullable).
--   2. Bucket PUBLIC `shop_logos` + policies RLS basées sur les
--      memberships actifs (role IN ('owner','admin') AND status='active').
--   3. NOTIFY pgrst — rechargement du cache schéma PostgREST.
--
-- Tout est idempotent : `ADD COLUMN IF NOT EXISTS`, `ON CONFLICT DO UPDATE`
-- pour le bucket, `DROP POLICY IF EXISTS` pour les policies. Ré-exécuter ce
-- script ne casse rien.
--
-- Convention de nommage des objets :  {shop_id}/logo.png
--   (overwrite à chaque upload — d'où la policy UPDATE distincte).
--
-- Limite par fichier : 200 KB · MIME : image/png, image/jpeg, image/webp
-- ════════════════════════════════════════════════════════════════════════════

-- ──────────────────────────────────────────────────────────────────────────
-- 1. Colonne `shops.logo_url`
-- ──────────────────────────────────────────────────────────────────────────
-- TEXT nullable. Lue / écrite côté client par `AppDatabase.updateShopLogoUrl`
-- et `_rowToShop`. Sans cette colonne, l'UPDATE `{logo_url: url}` échoue
-- avec 42703 column does not exist.
ALTER TABLE shops ADD COLUMN IF NOT EXISTS logo_url TEXT;

-- ──────────────────────────────────────────────────────────────────────────
-- 2. Bucket `shop_logos`
-- ──────────────────────────────────────────────────────────────────────────
-- public=true → lecture sans token (les widgets `Image.network` et le PDF
-- facture ouvrent l'URL directe sans s'authentifier).
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'shop_logos',
  'shop_logos',
  true,
  204800,                                          -- 200 KB
  ARRAY['image/png', 'image/jpeg', 'image/webp']
)
ON CONFLICT (id) DO UPDATE
  SET public             = EXCLUDED.public,
      file_size_limit    = EXCLUDED.file_size_limit,
      allowed_mime_types = EXCLUDED.allowed_mime_types;

-- ──────────────────────────────────────────────────────────────────────────
-- 3. Policies RLS — purge ANCIENNES (v1) + recréation propres (v2)
-- ──────────────────────────────────────────────────────────────────────────
-- v1 (initial — supprimées) : `shop_logos_(upload|update|delete)_own_shop`
-- v2 (actives) : nommage cohérent avec les actions PostgREST (select /
--   insert / update / delete), restriction explicite aux memberships
--   actifs avec rôle owner/admin (cashier/viewer n'ont pas le droit de
--   toucher au logo).
--
-- Le préfixe `(storage.foldername(name))[1]` extrait le `shop_id` du path
-- `{shop_id}/logo.png` pour cloisonner par boutique.

-- Purge ancienne génération (idempotent)
DROP POLICY IF EXISTS "shop_logos_upload_own_shop" ON storage.objects;
DROP POLICY IF EXISTS "shop_logos_update_own_shop" ON storage.objects;
DROP POLICY IF EXISTS "shop_logos_delete_own_shop" ON storage.objects;

-- Purge éventuelle re-création (rejouabilité de ce fichier)
DROP POLICY IF EXISTS "shop_logos_select" ON storage.objects;
DROP POLICY IF EXISTS "shop_logos_insert" ON storage.objects;
DROP POLICY IF EXISTS "shop_logos_update" ON storage.objects;
DROP POLICY IF EXISTS "shop_logos_delete" ON storage.objects;

-- SELECT — lecture publique (cohérent avec public=true du bucket).
-- Policy explicite plutôt que de s'appuyer uniquement sur le flag bucket :
-- rend l'intention lisible et survit à un changement de défaut Supabase.
CREATE POLICY "shop_logos_select"
  ON storage.objects FOR SELECT
  TO public
  USING (bucket_id = 'shop_logos');

-- INSERT — owner ou admin d'une membership ACTIVE de la shop.
CREATE POLICY "shop_logos_insert"
  ON storage.objects FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'shop_logos'
    AND (storage.foldername(name))[1] IN (
      SELECT m.shop_id::text
        FROM shop_memberships m
       WHERE m.user_id = auth.uid()::text
         AND m.role IN ('owner','admin')
         AND m.status = 'active'
    )
  );

-- UPDATE — même contrainte (nécessaire pour overwrite du même path).
CREATE POLICY "shop_logos_update"
  ON storage.objects FOR UPDATE
  TO authenticated
  USING (
    bucket_id = 'shop_logos'
    AND (storage.foldername(name))[1] IN (
      SELECT m.shop_id::text
        FROM shop_memberships m
       WHERE m.user_id = auth.uid()::text
         AND m.role IN ('owner','admin')
         AND m.status = 'active'
    )
  );

-- DELETE — bouton « Supprimer le logo » côté paramètres.
CREATE POLICY "shop_logos_delete"
  ON storage.objects FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'shop_logos'
    AND (storage.foldername(name))[1] IN (
      SELECT m.shop_id::text
        FROM shop_memberships m
       WHERE m.user_id = auth.uid()::text
         AND m.role IN ('owner','admin')
         AND m.status = 'active'
    )
  );

-- ──────────────────────────────────────────────────────────────────────────
-- 4. Recharger le cache schéma PostgREST
-- ──────────────────────────────────────────────────────────────────────────
-- Sans ce NOTIFY, PostgREST continue de servir l'ancien schéma cached et
-- répond `column "logo_url" does not exist` (PGRST204) jusqu'au prochain
-- redémarrage. Le canal `pgrst` est écouté par tous les workers.
NOTIFY pgrst, 'reload schema';
