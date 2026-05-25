-- ═════════════════════════════════════════════════════════════════════════════
-- hotfix_093 — Templates de livraison par partenaire (architecture hybride).
--
-- Contexte : avant ce hotfix, `delivery_templates` est shop-scoped et chaque
-- partenaire (stock_locations type='partner') porte un FK
-- `delivery_template_id` vers UN seul template. Le besoin produit demande
-- 0..N templates par partenaire, avec un défaut par partenaire et un
-- défaut shop-wide en fallback.
--
-- Architecture choisie : `delivery_templates.partner_id` nullable.
--   • partner_id IS NULL  → template shop-wide (rétro-compatible avec
--     l'existant : tous les templates pré-093 ont partner_id = NULL).
--   • partner_id IS NOT NULL → template spécifique à ce partenaire.
--
-- Règle de résolution au moment de l'envoi (cf. DeliveryTemplateRepository) :
--   1. (shop_id, partner_id = X, is_default = true) si présent
--   2. (shop_id, partner_id = X, *) premier match si présent (cas dégradé)
--   3. (shop_id, partner_id IS NULL, is_default = true) → défaut shop
--   4. (shop_id, partner_id IS NULL, *) → premier shop-wide (dégradé)
--
-- Migration purement ADDITIVE — aucun template existant n'est touché. Le
-- FK `stock_locations.delivery_template_id` reste valide en mode legacy
-- (pré-sélection explicite par le user dans LocationFormSheet) ; la
-- résolution par défaut basée sur partner_id le supplante quand
-- delivery_template_id est NULL.
-- ═════════════════════════════════════════════════════════════════════════════

-- 1) Colonne partner_id (nullable, ON DELETE CASCADE : si on supprime un
-- partenaire on ne garde pas ses templates orphelins).
ALTER TABLE delivery_templates
  ADD COLUMN IF NOT EXISTS partner_id uuid;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'delivery_templates_partner_fk'
  ) THEN
    ALTER TABLE delivery_templates
      ADD CONSTRAINT delivery_templates_partner_fk
      FOREIGN KEY (partner_id)
      REFERENCES stock_locations(id)
      ON DELETE CASCADE;
  END IF;
END$$;

-- 2) Index unique partial pour is_default : il doit y avoir au plus
-- UN défaut par (shop_id, partner_id). On utilise COALESCE pour
-- traiter NULL comme une valeur sentinelle stable — sinon plusieurs
-- défauts shop-wide pourraient coexister (Postgres considère
-- NULL ≠ NULL dans les contraintes uniques).
DROP INDEX IF EXISTS delivery_templates_default_uniq;

CREATE UNIQUE INDEX IF NOT EXISTS delivery_templates_default_per_scope_uniq
  ON delivery_templates (
    shop_id,
    COALESCE(partner_id, '00000000-0000-0000-0000-000000000000'::uuid)
  )
  WHERE is_default = true;

-- 3) Relâcher l'unique (shop_id, name) → (shop_id, partner_id, name) pour
-- permettre à 2 partenaires différents (ou shop-wide + partenaire) d'avoir
-- chacun un template "Standard" sans conflit.
ALTER TABLE delivery_templates
  DROP CONSTRAINT IF EXISTS delivery_templates_name_per_shop;

CREATE UNIQUE INDEX IF NOT EXISTS delivery_templates_name_per_scope_uniq
  ON delivery_templates (
    shop_id,
    COALESCE(partner_id, '00000000-0000-0000-0000-000000000000'::uuid),
    name
  );

-- 4) Index de lookup pour la résolution rapide par partenaire.
CREATE INDEX IF NOT EXISTS delivery_templates_partner_idx
  ON delivery_templates (partner_id, shop_id)
  WHERE partner_id IS NOT NULL;

-- 5) RLS : les policies existantes (delivery_templates_members) scopent
-- déjà par shop_id donc rien à modifier. Un membre du shop peut lire/
-- écrire les templates de tous les partenaires de son shop, ce qui est
-- l'intention (les permissions fines sont gérées côté app via
-- AppPermissions.canEditShopInfo).

COMMENT ON COLUMN delivery_templates.partner_id IS
  'NULL = template shop-wide. Sinon FK vers stock_locations(id) — '
  'template spécifique à un partenaire de livraison. Voir hotfix_093.';
