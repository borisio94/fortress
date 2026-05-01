-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_030_orders_reasons.sql
--
-- Ajoute deux colonnes texte sur `orders` pour tracer les raisons fournies
-- par l'opérateur lors d'une annulation ou d'une reprogrammation.
--
-- - cancellation_reason : raison saisie quand le client annule la commande
--   programmée. Reste affichée dans la fiche de la commande annulée.
--
-- - reschedule_reason   : raison saisie quand une commande "en cours" est
--   reprogrammée (empêchement client ou boutique). Sa simple présence sert
--   de marqueur "commande reprogrammée" pour différencier visuellement la
--   ligne dans l'onglet "Programmée".
--
-- Aucun défaut → les commandes existantes restent valides avec NULL.
-- ════════════════════════════════════════════════════════════════════════════

ALTER TABLE orders
  ADD COLUMN IF NOT EXISTS cancellation_reason TEXT,
  ADD COLUMN IF NOT EXISTS reschedule_reason   TEXT;
