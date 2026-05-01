-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_032_catalogues_bucket.sql
--
-- Bucket privé `catalogues` pour stocker les pages HTML statiques des
-- catalogues partagés par WhatsApp. Le HTML est uploadé par l'app, on
-- partage une signed URL à TTL court (48 h par défaut côté code) — passé
-- ce délai le lien expire pour éviter les catalogues fantômes.
--
-- Convention de chemin :
--   {shop_id}/{timestamp}.html
--   {shop_id}/promo-{timestamp}.html      (étape 6 — catalogue promo)
--
-- Le préfixe `{shop_id}` cloisonne via les policies : un membre de la
-- boutique X ne peut ni lire ni écrire les catalogues d'une autre boutique.
--
-- Limite : 2 MB par fichier · MIME accepté : text/html
-- ════════════════════════════════════════════════════════════════════════════

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'catalogues',
  'catalogues',
  false,
  2097152,
  ARRAY['text/html']
)
ON CONFLICT (id) DO UPDATE
  SET public             = EXCLUDED.public,
      file_size_limit    = EXCLUDED.file_size_limit,
      allowed_mime_types = EXCLUDED.allowed_mime_types;

DROP POLICY IF EXISTS "catalogues_upload_own_shop" ON storage.objects;
CREATE POLICY "catalogues_upload_own_shop"
  ON storage.objects FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'catalogues'
    AND (storage.foldername(name))[1] IN (
      SELECT s.id::text
        FROM shops s
       WHERE s.owner_id::text = auth.uid()::text
      UNION
      SELECT m.shop_id::text
        FROM shop_memberships m
       WHERE m.user_id::text = auth.uid()::text
    )
  );

DROP POLICY IF EXISTS "catalogues_read_own_shop" ON storage.objects;
CREATE POLICY "catalogues_read_own_shop"
  ON storage.objects FOR SELECT
  TO authenticated
  USING (
    bucket_id = 'catalogues'
    AND (storage.foldername(name))[1] IN (
      SELECT s.id::text
        FROM shops s
       WHERE s.owner_id::text = auth.uid()::text
      UNION
      SELECT m.shop_id::text
        FROM shop_memberships m
       WHERE m.user_id::text = auth.uid()::text
    )
  );

DROP POLICY IF EXISTS "catalogues_update_own_shop" ON storage.objects;
CREATE POLICY "catalogues_update_own_shop"
  ON storage.objects FOR UPDATE
  TO authenticated
  USING (
    bucket_id = 'catalogues'
    AND (storage.foldername(name))[1] IN (
      SELECT s.id::text
        FROM shops s
       WHERE s.owner_id::text = auth.uid()::text
      UNION
      SELECT m.shop_id::text
        FROM shop_memberships m
       WHERE m.user_id::text = auth.uid()::text
    )
  );

DROP POLICY IF EXISTS "catalogues_delete_own_shop" ON storage.objects;
CREATE POLICY "catalogues_delete_own_shop"
  ON storage.objects FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'catalogues'
    AND (storage.foldername(name))[1] IN (
      SELECT s.id::text
        FROM shops s
       WHERE s.owner_id::text = auth.uid()::text
      UNION
      SELECT m.shop_id::text
        FROM shop_memberships m
       WHERE m.user_id::text = auth.uid()::text
    )
  );

-- Note : aucune policy `anon`. La signed URL contient un token court qui
-- contourne RLS le temps de l'expiration (48 h par défaut, configurable
-- côté Dart via CatalogueStorageService.uploadCatalogue).
