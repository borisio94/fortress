-- hotfix_170_receptions_cost_only.sql
-- ═════════════════════════════════════════════════════════════════════════
-- LA FACTURE ARRIVE APRÈS LA MARCHANDISE — bon de « frais seuls ».
--
-- Le transport et la douane ne se paient presque jamais le jour où la
-- marchandise entre en rayon : la facture du transporteur ou le quittus de
-- douane tombent des jours, parfois des semaines plus tard. Entre-temps le
-- stock est entré, il s'est peut-être même déjà vendu.
--
-- L'arrivage valorisé (hotfix_163) ne savait poser ce coût qu'au moment de
-- l'entrée en stock. Passé ce moment, il ne restait qu'un mauvais choix :
-- créer un second arrivage — qui aurait doublé les quantités — ou corriger
-- le prix d'achat de chaque fiche à la main.
--
-- `cost_only = true` marque un bon qui ne fait entrer AUCUNE pièce. Ses
-- lignes désignent les pièces à qui répartir les frais, et la validation se
-- contente d'AJOUTER la part de frais au prix d'achat de chaque produit
-- (`+= frais/pièce`) — pas de moyenne pondérée, puisque aucune unité neuve
-- ne se mélange aux anciennes.
--
-- DÉFAUT `false` : tout bon antérieur faisait entrer de la marchandise,
-- c'était le seul type qui existait. Identique à la migration de schéma v3
-- côté Dart (`Reception._migrator`).
--
-- 100 % idempotent (ré-exécutable sans effet de bord).
-- ═════════════════════════════════════════════════════════════════════════

ALTER TABLE public.receptions
  ADD COLUMN IF NOT EXISTS cost_only BOOLEAN NOT NULL DEFAULT false;

COMMENT ON COLUMN public.receptions.cost_only IS
  'true = bon de frais seuls : aucune entrée de stock, les frais du lot '
  'sont imputés au prix d''achat des produits déjà en rayon. Voir '
  'hotfix_170.';
