-- hotfix_143_order_tab_label.sql
-- ═════════════════════════════════════════════════════════════════════════
-- COMPTES DE SERVICE — plusieurs additions par table (plan de salle, Lot 2).
--
-- `orders.tab_label` — libellé libre du compte auquel appartient la commande :
-- « Compte 1 », « M. Ali », « Groupe fenêtre »…
--
-- POURQUOI un libellé et pas une table `tabs` ni un rattachement client :
--   * Une table héberge plusieurs comptes simultanés (clients distincts assis
--     ensemble, groupes qui paieront séparément). Le lien commande → table
--     existe déjà (`orders.table_id`), il manquait seulement de quoi REGROUPER
--     les commandes d'un même payeur.
--   * Décision produit : PAS de création de fiche client pour un compte. En
--     service rapide, obliger à créer un client pour asseoir quelqu'un est
--     rédhibitoire. D'où un simple texte.
--   * Un compte peut vivre SANS table (plats à emporter) : c'est pour ça que
--     le libellé vit sur la commande et non sur la table. La table est un
--     attribut optionnel du compte, pas son propriétaire.
--
-- Une entité `tabs` dédiée ne se justifiera qu'au Lot 3 (transférer un compte
-- d'une table à une autre, fusionner, scinder) : un compte qui change de table
-- doit alors garder son identité, ce qu'un libellé ne permet pas.
--
-- Nullable, sans défaut : toutes les commandes existantes restent valides avec
-- `tab_label IS NULL` — une commande sans compte nommé, comme aujourd'hui.
--
-- 100 % idempotent (ré-exécutable sans effet de bord).
-- ═════════════════════════════════════════════════════════════════════════

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS tab_label TEXT;

COMMENT ON COLUMN public.orders.tab_label IS
  'Libellé libre du compte (addition) auquel appartient la commande. '
  'Plusieurs comptes coexistent sur une même table_id. NULL = commande sans '
  'compte nommé. Texte libre, sans lien avec les fiches clients.';

-- Regroupement des commandes ouvertes par compte, à l'échelle d'une boutique.
CREATE INDEX IF NOT EXISTS orders_tab_idx
  ON public.orders(shop_id, tab_label)
  WHERE tab_label IS NOT NULL;

-- ── Vérification ───────────────────────────────────────────────────────────
--   SELECT column_name, data_type, is_nullable
--     FROM information_schema.columns
--    WHERE table_name = 'orders' AND column_name = 'tab_label';
--
--   -- Doit renvoyer 0 tant qu'aucun compte n'a été nommé :
--   SELECT count(*) FROM public.orders WHERE tab_label IS NOT NULL;
--
--   -- Comptes ouverts d'une table :
--   SELECT tab_label, count(*), sum(total) FROM public.orders
--    WHERE table_id = '<rt_...>' AND status NOT IN ('completed','cancelled')
--    GROUP BY tab_label;
--
-- Fin — hotfix_143_order_tab_label.sql
