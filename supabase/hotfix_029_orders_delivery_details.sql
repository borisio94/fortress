-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_029_orders_delivery_details.sql
--
-- Étend les commandes avec les détails de livraison + expédition (agence).
--
-- - delivery_city / delivery_address  : peut différer de l'adresse client
--   (ex: livraison sur lieu de travail, chez un proche, etc.)
-- - shipment_*                         : utilisé quand mode='shipment'
--   (envoi via agence type DHL / Express Union)
--
-- Mode de livraison étendu :
--   pickup    | inHouse | partner | shipment(NEW)
--
-- Aucun défaut : les commandes existantes restent valides avec NULL,
-- l'app les traite comme "non renseigné" sans casser.
-- ════════════════════════════════════════════════════════════════════════════

ALTER TABLE orders
  ADD COLUMN IF NOT EXISTS delivery_city    TEXT,
  ADD COLUMN IF NOT EXISTS delivery_address TEXT,
  ADD COLUMN IF NOT EXISTS shipment_city    TEXT,
  ADD COLUMN IF NOT EXISTS shipment_agency  TEXT,
  ADD COLUMN IF NOT EXISTS shipment_handler TEXT;
