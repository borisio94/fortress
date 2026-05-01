-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_034_catalogues_pdf.sql
--
-- Migre le bucket `catalogues` du HTML vers le PDF.
--
-- Pourquoi : Supabase Storage convertit volontairement `text/html` en
-- `text/plain` quand servi depuis un bucket public (mesure anti-XSS), ce
-- qui empêche le rendu de la page côté navigateur. Les PDF n'ont pas
-- cette restriction → on bascule le format du catalogue vers PDF, qui
-- s'affiche nativement sur WhatsApp et dans tous les navigateurs.
--
-- Le bucket reste PUBLIC : l'URL `.../object/public/catalogues/…` sert
-- le PDF avec `Content-Type: application/pdf`, sans token, lisible par
-- tout destinataire WhatsApp sans authentification.
-- ════════════════════════════════════════════════════════════════════════════

UPDATE storage.buckets
   SET allowed_mime_types = ARRAY['application/pdf'],
       file_size_limit    = 10485760  -- 10 MB par fichier (catalogue + images)
 WHERE id = 'catalogues';
