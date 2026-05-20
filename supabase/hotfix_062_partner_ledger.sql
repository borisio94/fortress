-- hotfix_062_partner_ledger.sql
-- ─────────────────────────────────────────────────────────────────────────
-- Comptes partenaires : journalisation signée des flux financiers entre la
-- boutique et un dépôt partenaire (StockLocation type='partner').
--
-- Convention de signe sur `amount` :
--   * +N : le partenaire DOIT N à la boutique (vente encaissée par lui,
--          versement reçu par la boutique = en sens inverse).
--   * -N : la boutique DOIT N au partenaire (frais de livraison à payer,
--          ou versement effectué par la boutique au partenaire).
--
-- Solde par partenaire = SUM(amount) filtré sur partner_location_id.
-- ─────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.partner_ledger_entries (
  id                   TEXT        PRIMARY KEY,
  shop_id              TEXT        NOT NULL REFERENCES public.shops(id) ON DELETE CASCADE,
  partner_location_id  TEXT        NOT NULL REFERENCES public.stock_locations(id) ON DELETE CASCADE,
  order_id             TEXT,
  type                 TEXT        NOT NULL CHECK (type IN ('saleCollected','deliveryOwed','remittance')),
  amount               NUMERIC     NOT NULL,
  note                 TEXT,
  created_by_user_id   UUID,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS partner_ledger_shop_idx
  ON public.partner_ledger_entries(shop_id);
CREATE INDEX IF NOT EXISTS partner_ledger_partner_idx
  ON public.partner_ledger_entries(partner_location_id);
CREATE INDEX IF NOT EXISTS partner_ledger_order_idx
  ON public.partner_ledger_entries(order_id) WHERE order_id IS NOT NULL;

ALTER TABLE public.partner_ledger_entries ENABLE ROW LEVEL SECURITY;

-- RLS : on délègue le check d'appartenance au helper centralisé
-- public._is_shop_member(text) (cf. hotfix_041), qui gère le cast
-- text/uuid entre shops.id et shop_memberships.shop_id et inclut aussi
-- les owners directs et le super-admin global. Ainsi on évite de
-- dupliquer la logique RLS et les pièges de typage.
DROP POLICY IF EXISTS partner_ledger_members_or_owner
  ON public.partner_ledger_entries;
CREATE POLICY partner_ledger_members_or_owner
  ON public.partner_ledger_entries
  FOR ALL TO authenticated
  USING      (public._is_shop_member(shop_id))
  WITH CHECK (public._is_shop_member(shop_id));

-- Fin — hotfix_062_partner_ledger.sql
