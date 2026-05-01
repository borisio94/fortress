-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_031_factures_bucket.sql
--
-- Crée le bucket privé `factures` pour stocker les PDF de factures envoyés
-- aux clients via WhatsApp (wa.me). Les fichiers ne sont PAS publics : on
-- partage des `signed URLs` à expiration 30 jours, ce qui :
--   • garde les factures privées (pas indexables, pas devinables)
--   • permet au client (non-authentifié) d'ouvrir le lien depuis WhatsApp
--     pendant 30 jours, sans avoir de compte Supabase
--
-- Convention de nommage des objets :
--   {shop_id}/{order_id}.pdf
--
-- Le préfixe `{shop_id}` est utilisé par les policies pour cloisonner :
-- un membre de la boutique X ne peut ni lire ni écrire les factures
-- d'une autre boutique.
--
-- Limite par fichier : 10 MB · MIME accepté : application/pdf
-- ════════════════════════════════════════════════════════════════════════════

-- 1. Création du bucket (idempotent)
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'factures',
  'factures',
  false,
  10485760,
  ARRAY['application/pdf']
)
ON CONFLICT (id) DO UPDATE
  SET public             = EXCLUDED.public,
      file_size_limit    = EXCLUDED.file_size_limit,
      allowed_mime_types = EXCLUDED.allowed_mime_types;

-- 2. Policies storage.objects — cloisonnement par shop_id
-- ─────────────────────────────────────────────────────────
-- Helper : membre actif (owner OU shop_memberships) de la boutique
-- préfixant le path de l'objet.
DROP POLICY IF EXISTS "factures_upload_own_shop" ON storage.objects;
CREATE POLICY "factures_upload_own_shop"
  ON storage.objects FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'factures'
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

DROP POLICY IF EXISTS "factures_read_own_shop" ON storage.objects;
CREATE POLICY "factures_read_own_shop"
  ON storage.objects FOR SELECT
  TO authenticated
  USING (
    bucket_id = 'factures'
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

-- UPDATE : utile si on régénère une facture (même chemin → overwrite).
DROP POLICY IF EXISTS "factures_update_own_shop" ON storage.objects;
CREATE POLICY "factures_update_own_shop"
  ON storage.objects FOR UPDATE
  TO authenticated
  USING (
    bucket_id = 'factures'
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

-- DELETE : nettoyage manuel ou suppression de commande.
DROP POLICY IF EXISTS "factures_delete_own_shop" ON storage.objects;
CREATE POLICY "factures_delete_own_shop"
  ON storage.objects FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'factures'
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

-- Note : aucune policy pour `anon`. Les signed URLs (createSignedUrl côté
-- client) portent un token JWT court qui contourne RLS — le destinataire
-- WhatsApp ouvre le lien sans être authentifié, jusqu'à expiration.
