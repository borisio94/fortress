-- ═══════════════════════════════════════════════════════════════════════════
-- hotfix_067_share_previews_bucket.sql
--
-- Crée le bucket public `share-previews` qui contiendra des fichiers HTML
-- statiques avec og:tags personnalisés. Contournement du 403 que Cloudflare
-- inflige aux crawlers Facebook/WhatsApp sur `/functions/v1/` (Edge Functions).
--
-- Les URLs `/storage/v1/object/public/share-previews/<token>.html` passent
-- sans blocage, donc WhatsApp peut fetch les og:tags et générer la carte
-- de prévisualisation.
--
-- Sécurité :
--   • Bucket public en lecture (nécessaire pour les crawlers et users finaux)
--   • Upload restreint aux membres authentifiés d'une boutique
--   • Cleanup à prévoir (pg_cron qui purge fichiers > 30 jours)
-- ═══════════════════════════════════════════════════════════════════════════

INSERT INTO storage.buckets (id, name, public)
VALUES ('share-previews', 'share-previews', true)
ON CONFLICT (id) DO UPDATE SET public = true;

-- INSERT : tout utilisateur authentifié peut uploader (le token est random,
-- pas de risque de collision malveillante).
DROP POLICY IF EXISTS share_previews_insert ON storage.objects;
CREATE POLICY share_previews_insert ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'share-previews');

-- SELECT : public (déjà géré par `public = true` du bucket, mais on ajoute
-- une policy explicite pour clarté).
DROP POLICY IF EXISTS share_previews_select ON storage.objects;
CREATE POLICY share_previews_select ON storage.objects
  FOR SELECT TO anon, authenticated
  USING (bucket_id = 'share-previews');

-- DELETE : auteur uniquement (utile pour nettoyer si besoin).
DROP POLICY IF EXISTS share_previews_delete ON storage.objects;
CREATE POLICY share_previews_delete ON storage.objects
  FOR DELETE TO authenticated
  USING (bucket_id = 'share-previews' AND owner::text = auth.uid()::text);
