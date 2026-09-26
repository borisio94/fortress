-- hotfix_128_orders_delivery_fields.sql
-- ═════════════════════════════════════════════════════════════════════════
-- Champs livraison sur les commandes (PR-2 « frais de livraison par
-- quartier »). `delivery_city` existe déjà ; on ajoute le quartier, le prix
-- de livraison et la zone. Ces champs alimentent le message WhatsApp livreur,
-- la facture PDF et les rapports financiers.
--
-- `delivery_price` est en FCFA (entier). NULL = non renseigné (ex. commande
-- web « frais à fixer », cf. PR-3) ; le prix MAJORE le total à encaisser.
--
-- 100 % idempotent (ADD COLUMN IF NOT EXISTS).
-- ═════════════════════════════════════════════════════════════════════════

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS delivery_city     TEXT,
  ADD COLUMN IF NOT EXISTS delivery_quartier TEXT,
  ADD COLUMN IF NOT EXISTS delivery_price    INTEGER,
  ADD COLUMN IF NOT EXISTS delivery_zone     TEXT;

-- Fin — hotfix_128_orders_delivery_fields.sql
