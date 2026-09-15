-- hotfix_158_recipe_quantity_confirmed.sql
-- ═════════════════════════════════════════════════════════════════════════
-- `recipe_ingredients.quantity_confirmed` — la colonne manquante qui faisait
-- échouer la synchronisation des fiches techniques.
--
-- SYMPTÔME : bandeau « recipe_ingredients · upsert — Abandoned after 10
-- retries » dans la section restaurant.
--
-- CAUSE : le retour de la fiche technique (2026-08-07, deux méthodes de coût)
-- a ajouté le drapeau `quantityConfirmed` à l'entité Dart — la quantité
-- compte-t-elle dans le calcul, ou n'est-ce qu'une vieille saisie jamais
-- relue ? `RecipeIngredient.toMap()` écrit donc `quantity_confirmed`, mais
-- aucun hotfix ne l'a créée en base. PostgREST rejette l'upsert entier
-- (« Could not find the 'quantity_confirmed' column »), l'erreur est
-- PERMANENTE, et la table n'étant pas critique la file l'abandonne au bout de
-- 10 essais — la ligne reste correcte dans Hive mais ne part jamais.
--
-- Le défaut est plus large que la colonne : l'upsert échouait EN ENTIER, donc
-- ni le poids de portion ni la quantité ne remontaient. Un appareil qui
-- n'aurait jamais vu ces fiches en local les croirait inexistantes.
--
-- DÉFAUT : false — « quantité non confirmée ». C'est exactement ce que fait la
-- migration de schéma v2 côté Dart (`_markLegacyQuantityUnconfirmed`) : une
-- quantité saisie avant le retour de la fiche technique n'a pas été relue
-- depuis, et la chiffrer sans confirmation produirait un coût théorique faux
-- ET plausible — le pire des deux. Les lignes existantes gardent donc leur
-- quantité, simplement inerte tant que personne ne l'a confirmée à l'écran.
--
-- 100 % idempotent (ré-exécutable sans effet de bord).
-- ═════════════════════════════════════════════════════════════════════════

ALTER TABLE public.recipe_ingredients
  ADD COLUMN IF NOT EXISTS quantity_confirmed BOOLEAN NOT NULL DEFAULT false;

COMMENT ON COLUMN public.recipe_ingredients.quantity_confirmed IS
  'La quantité a-t-elle été confirmée DEPUIS le retour de la fiche technique '
  '(hotfix_158) ? false = suggestion pré-remplie dans le formulaire, exclue '
  'de tout calcul de coût. Seule la méthode « fiche technique » la lit ; la '
  'répartition au prorata ignore quantity et quantity_confirmed.';

-- ── Vérification ─────────────────────────────────────────────────────────
--
--   SELECT column_name, data_type, column_default, is_nullable
--     FROM information_schema.columns
--    WHERE table_name = 'recipe_ingredients'
--      AND column_name = 'quantity_confirmed';
--
--   -- Fiches remontées, et combien de lignes confirmées :
--   SELECT shop_id,
--          count(*)                                    AS lignes,
--          count(*) FILTER (WHERE quantity_confirmed)  AS confirmees
--     FROM public.recipe_ingredients
--    GROUP BY shop_id;
--
-- ── Après application ────────────────────────────────────────────────────
--
-- Les upserts encore EN ATTENTE dans la file repartiront tout seuls à la
-- prochaine tentative. En revanche, les ops déjà « abandonnées » ont été
-- SUPPRIMÉES de la file : « Tout réessayer » ne les ressuscite pas. Pour ces
-- lignes-là, rouvrir la fiche du plat et la ré-enregistrer — la donnée est
-- intacte dans Hive, seul le push a été perdu.
