-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_035_catalogues_cover_png.sql
--
-- Autorise les images PNG dans le bucket `catalogues`. Pourquoi : WhatsApp
-- ne sait pas générer d'aperçu pour un PDF. On rasterise donc la 1ʳᵉ page
-- du catalogue PDF en PNG (côté app via le package `printing`), on l'upload
-- à côté du PDF, et on met l'URL de l'image en première ligne du message
-- wa.me — WhatsApp preview alors l'image, le lien PDF reste juste en dessous.
--
-- Le MIME `image/png` doit être ajouté aux types autorisés. La taille
-- limite reste à 10 MB (suffit largement pour une page A4 rasterisée à 144 DPI).
-- ════════════════════════════════════════════════════════════════════════════

UPDATE storage.buckets
   SET allowed_mime_types = ARRAY['application/pdf', 'image/png']
 WHERE id = 'catalogues';
