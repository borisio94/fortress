-- hotfix_155_accompagnements.sql
-- ═════════════════════════════════════════════════════════════════════════
-- ACCOMPAGNEMENTS OBLIGATOIRES SUR UN PLAT.
--
-- Un riz ne se sert pas sans sauce, ni la sauce sans viande :
--
--   Riz
--    └─ Sauce   (obligatoire) : tomate · arachide · émincée · ndolé
--        └─ Viande (obligatoire) : porc · poisson · poulet
--
-- `menu_modifiers.is_required` marque un groupe dont le choix ne peut pas être
-- omis. Sans lui, rien n'empêchait d'envoyer en cuisine un bon que le
-- cuisinier devait venir faire préciser.
--
-- L'AUTRE MOITIÉ DU BESOIN NE DEMANDE AUCUNE MIGRATION : chaque option gagne
-- un `product_id` qui la relie à un plat de la carte (« Sauce d'arachide »,
-- « Poulet »), et `options` est déjà une colonne JSONB — le champ s'y ajoute
-- sans toucher au schéma.
--
-- Pourquoi ce lien compte : une option ne portait qu'un prix, jamais de
-- matière. « Riz sauce arachide poulet » et « Riz sauce tomate poisson »
-- affichaient donc le même coût — celui du riz seul. En pointant un plat,
-- l'option hérite de ses ingrédients et de ses achats, et la répartition la
-- compte comme vendue sans qu'aucune quantité soit saisie.
--
-- 100 % idempotent (ré-exécutable sans effet de bord).
-- ═════════════════════════════════════════════════════════════════════════

ALTER TABLE public.menu_modifiers
  ADD COLUMN IF NOT EXISTS is_required BOOLEAN NOT NULL DEFAULT false;

COMMENT ON COLUMN public.menu_modifiers.is_required IS
  'Le groupe exige un choix à la prise de commande (hotfix_155). Défaut '
  'false : les groupes existants restent facultatifs, comme ils l''étaient.';

COMMENT ON COLUMN public.menu_modifiers.options IS
  'Options du groupe (JSONB). Chaque entrée : name · price_impact · '
  'product_id (hotfix_155, optionnel — plat de la carte que l''option '
  'représente, ce qui lui donne un coût matières).';

-- ── Vérification ───────────────────────────────────────────────────────────
--   SELECT column_name, column_default FROM information_schema.columns
--    WHERE table_name = 'menu_modifiers' AND column_name = 'is_required';
--
--   -- Groupes obligatoires et leurs options adossées à un plat :
--   SELECT name, is_required,
--          jsonb_array_elements(options) ->> 'name'       AS option,
--          jsonb_array_elements(options) ->> 'product_id' AS plat
--     FROM public.menu_modifiers
--    WHERE shop_id = '<shop>' ORDER BY name;
--
-- Fin — hotfix_155_accompagnements.sql
