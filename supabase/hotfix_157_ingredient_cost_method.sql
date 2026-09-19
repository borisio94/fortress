-- hotfix_157 — méthode de chiffrage PAR INGRÉDIENT.
--
-- Remplace le réglage par boutique (préférence locale `dish_cost_method_<shopId>`,
-- supprimé côté application) : deux familles d'ingrédients coexistent dans une
-- cuisine et ne se mesurent pas de la même façon.
--
--   * 'repartition' — les achats du mois se répartissent entre les plats vendus
--     qui contiennent l'ingrédient. Aucune quantité à peser. C'est la seule
--     méthode possible pour ce qui s'achète en tas : piment, cubes, épices.
--
--   * 'fiche' — la quantité par portion, saisie dans la fiche recette, est
--     multipliée par le coût unitaire moyen. Réservée à ce qui se pèse
--     réellement : riz, huile, viande. C'est elle, et elle seule, qui permet de
--     détecter un sur-dosage.
--
-- DÉFAUT 'repartition' : tout le parc existant garde exactement le
-- comportement qu'il avait. Rien ne change tant qu'un ingrédient n'est pas
-- basculé à la main.
--
-- ⚠ À APPLIQUER AVANT LE DÉPLOIEMENT DE L'APPLICATION. La table `ingredients`
-- se synchronise en passthrough : la map complète part vers Supabase. Sans
-- cette colonne, tout upsert d'ingrédient serait rejeté puis abandonné en
-- silence après dix tentatives (cf. hotfix_082, même piège sur
-- stock_movements.reason).

ALTER TABLE ingredients
  ADD COLUMN IF NOT EXISTS cost_method TEXT
  DEFAULT 'repartition';

-- Contrainte posée SÉPARÉMENT et après le DEFAULT : sur une table déjà
-- peuplée, un ADD COLUMN ... CHECK échouerait si une ligne existante ne la
-- satisfaisait pas. Ici le DEFAULT garantit qu'aucune ne peut être hors
-- domaine, mais l'ordre reste le bon réflexe.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'ingredients_cost_method_check'
  ) THEN
    ALTER TABLE ingredients
      ADD CONSTRAINT ingredients_cost_method_check
      CHECK (cost_method IN ('repartition', 'fiche'));
  END IF;
END $$;

-- Lignes antérieures à la colonne : le DEFAULT ne s'applique qu'aux insertions.
UPDATE ingredients SET cost_method = 'repartition' WHERE cost_method IS NULL;
