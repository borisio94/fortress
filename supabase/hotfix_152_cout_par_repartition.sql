-- hotfix_152_cout_par_repartition.sql
-- ═════════════════════════════════════════════════════════════════════════
-- COÛT MATIÈRES PAR RÉPARTITION AU PRORATA DES VENTES.
--
-- Remplace la méthode précédente, qui exigeait une QUANTITÉ PAR PLAT dans
-- chaque fiche recette, puis divisait le coût d'un ingrédient « partagé » par
-- le nombre de plats l'employant. Deux défauts rédhibitoires :
--
--   * personne ne pèse 125 g de poulet par assiette en plein service — la
--     fiche technique restait vide, donc le coût matières restait à zéro et la
--     marge affichée était fausse dans le sens le plus flatteur ;
--   * le prorata facturait 1/3 de litre d'huile à un plat dont la vente en
--     retirait un litre entier du stock.
--
-- LA NOUVELLE MÉTHODE ne demande AUCUNE quantité. On déclare seulement quels
-- plats contiennent quel ingrédient, et le coût réellement dépensé pour cet
-- ingrédient est réparti entre eux au prorata de ce qui s'est vendu :
--
--   part d'un plat = dépense_ingrédient × poids_portion
--                    ÷ Σ (quantités vendues × poids_portion)
--
-- Deux changements de schéma :
--
--   1. `recipe_ingredients.portion_weight` — la générosité de la portion
--      (0,5 petite · 1 normale · 1,5 grande). C'est un CHOIX, pas une pesée :
--      il dit qu'un plat est plus copieux qu'un autre, rien de plus.
--      `quantity` est CONSERVÉE mais n'est plus lue : c'est une donnée que
--      l'utilisateur a saisie, et elle redeviendrait exploitable si l'on
--      revenait un jour à une fiche technique pesée.
--
--   2. `daily_expenses.ingredient_id` — QUEL ingrédient cette dépense a
--      acheté. C'est le lien qui rend tout le calcul possible : sans lui,
--      l'argent sort de la caisse mais aucune assiette ne sait qu'elle l'a
--      consommé.
--
-- CONSÉQUENCE ASSUMÉE, à connaître avant d'appliquer : le stock des
-- ingrédients n'est PLUS décrémenté à la vente. Sans quantité par plat, il n'y
-- a rien à retirer. Il ne bouge plus que par réception et par comptage
-- d'inventaire.
--
-- PAS DE FK sur `ingredient_id` (même raison que hotfix_140 / _141) : en
-- offline-first l'ordre des upserts n'est pas garanti, une dépense poussée
-- avant son ingrédient violerait la contrainte et l'op serait abandonnée après
-- dix essais. Référence logique, intégrité tenue côté application.
--
-- 100 % idempotent (ré-exécutable sans effet de bord).
-- ═════════════════════════════════════════════════════════════════════════

-- ══════════════════════════════════════════════════════════════════════════
-- 1. COMPOSITION DES PLATS — générosité de la portion.
-- ══════════════════════════════════════════════════════════════════════════
-- Défaut 1 : toutes les lignes déjà saisies deviennent des portions normales,
-- donc se répartissent à parts égales. Aucune fiche existante n'est perdue ni
-- déformée.
ALTER TABLE public.recipe_ingredients
  ADD COLUMN IF NOT EXISTS portion_weight NUMERIC NOT NULL DEFAULT 1;

-- Un poids négatif rendrait une part de coût négative et gonflerait la marge
-- du plat. Le plafond à 5 arrête une faute de frappe (15 au lieu de 1,5) avant
-- qu'elle ne siphonne toute la répartition sur un seul plat.
ALTER TABLE public.recipe_ingredients
  DROP CONSTRAINT IF EXISTS recipe_ingredients_portion_weight_check;

ALTER TABLE public.recipe_ingredients
  ADD CONSTRAINT recipe_ingredients_portion_weight_check
  CHECK (portion_weight >= 0 AND portion_weight <= 5);

COMMENT ON COLUMN public.recipe_ingredients.portion_weight IS
  'Générosité de la portion, relative à une part normale (hotfix_152). '
  '0,5 petite · 1 normale · 1,5 grande. Pondère la répartition du coût de '
  'l''ingrédient entre les plats qui le contiennent.';

COMMENT ON COLUMN public.recipe_ingredients.quantity IS
  'LEGACY depuis hotfix_152 — quantité par plat des fiches techniques '
  'pesées. N''entre plus dans aucun calcul, conservée pour ne pas détruire '
  'une saisie utilisateur.';

-- La répartition lit TOUS les liens d'une boutique en une passe.
CREATE INDEX IF NOT EXISTS recipe_ingredients_shop_idx
  ON public.recipe_ingredients(shop_id);

-- ══════════════════════════════════════════════════════════════════════════
-- 2. DÉPENSES — quel ingrédient a été acheté.
-- ══════════════════════════════════════════════════════════════════════════
ALTER TABLE public.daily_expenses
  ADD COLUMN IF NOT EXISTS ingredient_id TEXT;

COMMENT ON COLUMN public.daily_expenses.ingredient_id IS
  'Ingrédient acheté par cette dépense (ingredients.id, hotfix_152). NULL = '
  'dépense non rattachée : elle compte dans le food cost global mais n''est '
  'imputée à aucun plat. Référence logique, sans FK (offline-first).';

-- « Ce que le poulet a coûté en juillet » — LA requête de la répartition.
-- Index partiel : les dépenses non rattachées (gaz, loyer, transport) n'y
-- entrent pas, il reste donc petit.
CREATE INDEX IF NOT EXISTS daily_expenses_ingredient_idx
  ON public.daily_expenses(shop_id, ingredient_id, expense_date)
  WHERE ingredient_id IS NOT NULL;

-- ── Vérification ───────────────────────────────────────────────────────────
--   -- Les deux colonnes existent :
--   SELECT table_name, column_name, column_default
--     FROM information_schema.columns
--    WHERE (table_name='recipe_ingredients' AND column_name='portion_weight')
--       OR (table_name='daily_expenses'     AND column_name='ingredient_id');
--
--   -- Coût d'un plat sur un mois (remplacer <shop> et les dates) :
--   WITH ventes AS (
--     SELECT (item->>'product_id') AS product_id,
--            sum((item->>'quantity')::numeric) AS qte
--       FROM public.orders o, jsonb_array_elements(o.items) AS item
--      WHERE o.shop_id='<shop>' AND o.status='completed'
--        AND o.deleted_at IS NULL
--        AND o.completed_at::date BETWEEN DATE '2026-07-01' AND DATE '2026-07-31'
--      GROUP BY 1
--   ),
--   depenses AS (
--     SELECT ingredient_id, sum(amount) AS montant
--       FROM public.daily_expenses
--      WHERE shop_id='<shop>' AND ingredient_id IS NOT NULL
--        AND expense_date BETWEEN DATE '2026-07-01' AND DATE '2026-07-31'
--      GROUP BY 1
--   ),
--   parts AS (
--     SELECT ri.ingredient_id, ri.product_id, ri.portion_weight,
--            COALESCE(v.qte,0) * ri.portion_weight AS part
--       FROM public.recipe_ingredients ri
--       LEFT JOIN ventes v ON v.product_id = ri.product_id
--      WHERE ri.shop_id='<shop>'
--   )
--   SELECT p.product_id,
--          sum(d.montant * p.part / NULLIF(t.total,0)) AS cout_par_plat
--     FROM parts p
--     JOIN depenses d ON d.ingredient_id = p.ingredient_id
--     JOIN (SELECT ingredient_id, sum(part) AS total FROM parts GROUP BY 1) t
--       ON t.ingredient_id = p.ingredient_id
--    WHERE p.part > 0
--    GROUP BY 1 ORDER BY 2 DESC;
--
-- Fin — hotfix_152_cout_par_repartition.sql
