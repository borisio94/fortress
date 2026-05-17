-- hotfix_071_partner_charges.sql
-- ─────────────────────────────────────────────────────────────────────────
-- Charges de la boutique envers un partenaire (au-delà des frais de
-- livraison réussie déjà couverts par `deliveryOwed`).
--
-- Nouveau type `partnerCharge` (amount NÉGATIF — la boutique doit) avec une
-- sous-catégorie libre `category` :
--   * failedDelivery : course due alors que le client a refusé la livraison
--   * storage        : frais de dépôt / stockage
--   * commission     : commission du partenaire
--   * subscription   : abonnement / forfait récurrent
--   * handling       : manutention
--   * other          : autre
--
-- `deliveryOwed` reste STRICTEMENT « livraison réussie » → les KPI de
-- livraison restent propres. Le cash ne sort des Finances qu'au moment du
-- `remittance` négatif (versement réel), pas à l'accumulation de la charge.
-- ─────────────────────────────────────────────────────────────────────────

ALTER TABLE public.partner_ledger_entries
  DROP CONSTRAINT IF EXISTS partner_ledger_entries_type_check;

ALTER TABLE public.partner_ledger_entries
  ADD CONSTRAINT partner_ledger_entries_type_check
  CHECK (type IN ('saleCollected','deliveryOwed','remittance','partnerCharge'));

ALTER TABLE public.partner_ledger_entries
  ADD COLUMN IF NOT EXISTS category TEXT;

-- Fin — hotfix_071_partner_charges.sql
