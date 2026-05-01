-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_033_catalogues_public.sql
--
-- Bascule le bucket `catalogues` en public.
--
-- Pourquoi : les signed URLs (bucket privé) forcent
--   `Content-Disposition: attachment` sur les fichiers `text/html` pour
-- bloquer une éventuelle injection XSS via contenu hébergé. Résultat :
-- WhatsApp / le navigateur du client TÉLÉCHARGE le HTML au lieu de
-- l'afficher.
--
-- Solution : bucket public → URL `…/storage/v1/object/public/catalogues/…`
-- qui sert le HTML avec `Content-Disposition: inline`. Le HTML s'affiche
-- correctement dans le navigateur.
--
-- Confidentialité :
--   • L'URL contient `{shop_id (UUID)}/{timestamp}.html` — non devinable.
--   • Le catalogue est destiné à être partagé via WhatsApp → pas de PII
--     sensible attendu (noms / prix produits uniquement).
--   • L'expiration "48 h" devient une règle applicative (cleanup cron)
--     plutôt qu'une garantie cryptographique. À ajouter plus tard.
--
-- Les policies upload/update/delete restent restreintes aux membres de la
-- boutique. SEUL le SELECT est ouvert (déjà géré par `public=true`).
-- ════════════════════════════════════════════════════════════════════════════

UPDATE storage.buckets
   SET public = true
 WHERE id = 'catalogues';
