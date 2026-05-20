-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_077_shop_whatsapp_phone.sql
--
-- Numéro WhatsApp DÉDIÉ par boutique, distinct du téléphone affiché
-- (`shops.phone`). Les liens wa.me (catalogue public, commandes) utilisent
-- `whatsapp_phone` s'il est renseigné, sinon repli sur `phone` (aucun
-- changement de comportement pour les boutiques existantes).
--
-- 100 % idempotent.
-- ════════════════════════════════════════════════════════════════════════════

ALTER TABLE public.shops
  ADD COLUMN IF NOT EXISTS whatsapp_phone text;

-- Vérif : SELECT id, name, phone, whatsapp_phone FROM shops LIMIT 5;
