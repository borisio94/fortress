-- hotfix_169_product_unit_notes.sql
-- ═════════════════════════════════════════════════════════════════════════
-- DEUX CHAMPS SAISIS MAIS JAMAIS ENREGISTRÉS — unité et notes internes.
--
-- La fiche produit propose depuis toujours un sélecteur « Unité de mesure »
-- et un champ « Notes internes ». Ni l'un ni l'autre n'était écrit : la
-- saisie disparaissait à l'enregistrement, sans le moindre message. Ces
-- deux colonnes leur donnent enfin une place.
--
-- POURQUOI PAS LES DIMENSIONS. Le plan d'origine prévoyait aussi
-- `weight_g`, `length_cm`, `width_cm` et `height_cm` sur une table
-- `product_variants`. Cette table N'EXISTE PAS : les variantes sont
-- stockées en JSONB dans `products.variants`. Ce hotfix aurait donc échoué.
-- Les quatre dimensions sont persistées dans ce JSON, sans colonne dédiée
-- ni migration — elles suivent le même chemin que le prix ou le SKU d'une
-- variante.
--
-- `internal_notes` est une note de gestion : elle n'est exposée par AUCUNE
-- RPC publique, et le catalogue en ligne ne la voit pas.
--
-- 100 % idempotent (ré-exécutable sans effet de bord).
-- ═════════════════════════════════════════════════════════════════════════

ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS unit           TEXT,
  ADD COLUMN IF NOT EXISTS internal_notes TEXT;

COMMENT ON COLUMN public.products.unit IS
  'Unité de mesure affichée sur la fiche (pièce, kg, litre…). Saisie libre '
  'par boutique. Voir hotfix_169.';

COMMENT ON COLUMN public.products.internal_notes IS
  'Note de gestion, à usage interne. Jamais exposée par les RPC publiques '
  'ni par le catalogue en ligne. Voir hotfix_169.';

-- Recharge le cache de schéma PostgREST (sinon PGRST204 quelques minutes).
NOTIFY pgrst, 'reload schema';
