-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_051_partner_city_district.sql
--
-- Ajoute deux colonnes optionnelles à `stock_locations` pour permettre de
-- saisir séparément la ville et le quartier d'un dépôt partenaire (au
-- lieu de tout mettre dans `address`). Utilisées notamment pour
-- pré-remplir `{{ville_expedition}}` lors d'un transfert au livreur
-- (cf. hotfix_049/050).
--
-- Le champ `address` legacy est conservé pour rétrocompatibilité — les
-- partenaires existants gardent leur adresse, le formulaire ne l'efface
-- pas. Les nouvelles entrées remplissent `city` / `district` directement.
--
-- Idempotent.
-- ════════════════════════════════════════════════════════════════════════════

ALTER TABLE stock_locations
  ADD COLUMN IF NOT EXISTS city     text,
  ADD COLUMN IF NOT EXISTS district text;
