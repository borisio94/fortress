-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_087_shop_logos_bucket.sql
--
-- Crée le bucket PUBLIC `shop_logos` pour stocker les logos de boutiques.
-- Diffère de `factures` (privé + signed URLs) parce que le logo est
-- embarqué dans le PDF facture côté client : il faut pouvoir le fetcher
-- via une URL publique stable sans devoir signer à chaque ouverture.
--
-- Convention de nommage des objets :
--   {shop_id}/logo.png    (overwrite à chaque upload)
--
-- Le préfixe `{shop_id}` est utilisé par les policies WRITE pour
-- cloisonner : un membre de la boutique X ne peut ni écrire ni
-- remplacer le logo d'une autre boutique. SELECT reste public car
-- le bucket est public_read.
--
-- Limite par fichier : 200 KB · MIME : image/png, image/jpeg, image/webp
-- ════════════════════════════════════════════════════════════════════════════

-- 1. Création du bucket (idempotent)
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'shop_logos',
  'shop_logos',
  true,                                            -- lecture publique
  204800,                                          -- 200 KB
  ARRAY['image/png', 'image/jpeg', 'image/webp']
)
ON CONFLICT (id) DO UPDATE
  SET public             = EXCLUDED.public,
      file_size_limit    = EXCLUDED.file_size_limit,
      allowed_mime_types = EXCLUDED.allowed_mime_types;

-- 2. Policies storage.objects — écriture restreinte au shop, lecture publique
-- ──────────────────────────────────────────────────────────────────────────

-- INSERT : owner ou membre de la shop préfixant le path
DROP POLICY IF EXISTS "shop_logos_upload_own_shop" ON storage.objects;
CREATE POLICY "shop_logos_upload_own_shop"
  ON storage.objects FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'shop_logos'
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

-- UPDATE : nécessaire pour overwrite (upload du même path lors d'un
-- changement de logo). Sinon il faudrait DELETE + INSERT à chaque
-- changement, ce qui invalide l'URL publique pendant la fenêtre.
DROP POLICY IF EXISTS "shop_logos_update_own_shop" ON storage.objects;
CREATE POLICY "shop_logos_update_own_shop"
  ON storage.objects FOR UPDATE
  TO authenticated
  USING (
    bucket_id = 'shop_logos'
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

-- DELETE : suppression manuelle du logo (bouton supprimer dans
-- paramètres). Le `shops.logo_url` est mis à null en parallèle côté
-- table — la policy UPDATE de la table `shops` couvre déjà ce point.
DROP POLICY IF EXISTS "shop_logos_delete_own_shop" ON storage.objects;
CREATE POLICY "shop_logos_delete_own_shop"
  ON storage.objects FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'shop_logos'
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

-- SELECT : aucune policy explicite — bucket `public=true` rend les
-- objets accessibles via `storage/v1/object/public/shop_logos/...`
-- sans token. C'est nécessaire pour que le widget `Image.network` côté
-- client (et le `http.get` du fetch PDF) ouvre l'URL sans auth.
