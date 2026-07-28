-- hotfix_142_ingredient_purchase_date.sql
-- ═════════════════════════════════════════════════════════════════════════
-- DATE D'ACHAT SUR LES INGRÉDIENTS.
--
-- `ingredients.purchase_date` — quand l'ingrédient a été acheté. Champ
-- PUREMENT INFORMATIF (traçabilité, affiché dans la liste des ingrédients).
--
-- Ce qu'il n'est PAS : une écriture comptable. Le bénéfice continue de se
-- calculer à la VENTE, via le coût matières de la fiche recette
-- (RestaurantReportingService). Faire de cette date une dépense du jour
-- compterait la même marchandise deux fois — une fois à l'achat, une fois
-- quand le plat se vend. Un vrai carnet d'achats reste à construire si l'on
-- veut basculer en comptabilité de caisse.
--
-- Nullable, sans défaut : tous les ingrédients existants restent valides avec
-- `purchase_date IS NULL` (« date non renseignée »). Aucune migration de
-- données, aucun bump de `schema_version` côté Dart — l'absence de clé se lit
-- déjà comme null.
--
-- 100 % idempotent (ré-exécutable sans effet de bord).
-- ═════════════════════════════════════════════════════════════════════════

ALTER TABLE public.ingredients
  ADD COLUMN IF NOT EXISTS purchase_date DATE;

COMMENT ON COLUMN public.ingredients.purchase_date IS
  'Date d''achat de l''ingrédient — informatif (traçabilité). N''entre PAS '
  'dans le calcul du bénéfice : le coût matières est compté à la vente via '
  'la fiche recette. NULL = non renseignée.';

-- ── Vérification ───────────────────────────────────────────────────────────
--   SELECT column_name, data_type, is_nullable
--     FROM information_schema.columns
--    WHERE table_name = 'ingredients' AND column_name = 'purchase_date';
--
--   -- Doit renvoyer 0 tant qu'aucune date n'a été saisie :
--   SELECT count(*) FROM public.ingredients WHERE purchase_date IS NOT NULL;
--
-- Fin — hotfix_142_ingredient_purchase_date.sql
