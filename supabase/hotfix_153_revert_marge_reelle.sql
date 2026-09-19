-- hotfix_153_revert_marge_reelle.sql
-- ═════════════════════════════════════════════════════════════════════════
-- RÉVOCATION DE hotfix_151_marge_reelle.sql
--
-- hotfix_151 accompagnait une méthode de calcul (coût des matières consommées
-- par variation de stock + coût partagé par assiette) qui a été ABANDONNÉE et
-- retirée du code. Plus aucune ligne de l'application ne lit ni n'écrit ce
-- qu'il a créé : les objets restent en base sans jamais servir.
--
-- Ce script les retire. Il est SANS EFFET si hotfix_151 n'a jamais été appliqué.
--
-- ⚠ CE SCRIPT DÉTRUIT DES DONNÉES — lisez la section 1 avant de l'exécuter.
--
-- Il ne touche PAS à hotfix_152 (portion_weight, ingredient_id), qui porte la
-- méthode ACTUELLE et doit rester en place.
--
-- 100 % idempotent (ré-exécutable sans effet de bord).
-- ═════════════════════════════════════════════════════════════════════════

-- ══════════════════════════════════════════════════════════════════════════
-- 1. TABLE inventory_snapshots — les photos de stock.
-- ══════════════════════════════════════════════════════════════════════════
-- DESTRUCTIF : la table et son contenu disparaissent. Si vous avez fait des
-- comptages d'inventaire pendant les quelques heures où la fonctionnalité
-- était en ligne, ces valorisations seront perdues.
--
-- VÉRIFIEZ D'ABORD ce que vous allez perdre :
--
--   SELECT count(*) AS photos, min(snapshot_date), max(snapshot_date)
--     FROM public.inventory_snapshots;
--
-- Si le compte est à 0, la suppression ne coûte rien. S'il ne l'est pas et que
-- vous voulez garder une trace, exportez d'abord :
--
--   SELECT * FROM public.inventory_snapshots ORDER BY snapshot_date;
--
-- Les policies RLS et l'appartenance à la publication `supabase_realtime`
-- disparaissent avec la table — aucun nettoyage séparé n'est nécessaire.
DROP TABLE IF EXISTS public.inventory_snapshots;

-- ══════════════════════════════════════════════════════════════════════════
-- 2. COLONNE products.shared_cost_coef — le coefficient de charge partagée.
-- ══════════════════════════════════════════════════════════════════════════
-- Aucune donnée métier n'est perdue : l'application ne l'a jamais écrite
-- autrement qu'à sa valeur par défaut (1), et l'entité `Product` ne la connaît
-- plus depuis le retrait de la méthode.
--
-- PRÉ-REQUIS : que plus aucun client ne l'envoie. La version déployée ne
-- l'envoie pas, et `main.dart.js` est servi en `no-cache` — tout navigateur
-- récupère donc la version courante au premier rechargement. Si un poste
-- tournait encore l'ancienne version, ses upserts produits seraient rejetés
-- jusqu'à ce qu'il recharge.
ALTER TABLE public.products
  DROP CONSTRAINT IF EXISTS products_shared_cost_coef_check;

ALTER TABLE public.products
  DROP COLUMN IF EXISTS shared_cost_coef;

-- ══════════════════════════════════════════════════════════════════════════
-- 3. INDEX de daily_expenses — retour à ceux de hotfix_149.
-- ══════════════════════════════════════════════════════════════════════════
-- hotfix_151 avait remplacé l'index des achats au marché par deux index
-- taillés pour ses propres requêtes (matières directes + vrac, puis vrac +
-- combustible). Ces requêtes n'existent plus.
DROP INDEX IF EXISTS public.daily_expenses_material_idx;
DROP INDEX IF EXISTS public.daily_expenses_shared_idx;

-- Restauration de l'index d'origine, supprimé par hotfix_151.
CREATE INDEX IF NOT EXISTS daily_expenses_market_idx
  ON public.daily_expenses(shop_id, expense_date)
  WHERE category = 'achat_marche';

-- ══════════════════════════════════════════════════════════════════════════
-- 4. CATÉGORIE 'achat_vrac' — VOLONTAIREMENT CONSERVÉE.
-- ══════════════════════════════════════════════════════════════════════════
-- hotfix_151 avait élargi le CHECK de `daily_expenses.category` pour accepter
-- 'achat_vrac'. Cette valeur n'est PLUS jamais émise par l'application.
--
-- On ne resserre pas le CHECK, et c'est un choix :
--   * une contrainte plus PERMISSIVE que nécessaire n'a aucun effet — elle
--     n'autorise que ce que personne n'écrit ;
--   * la resserrer ÉCHOUERAIT si une seule ligne portait déjà cette catégorie,
--     laissant la migration à moitié appliquée.
--
-- Si vous tenez à la resserrer, exécutez le bloc ci-dessous SÉPARÉMENT. Il
-- refuse de s'exécuter tant qu'il reste des lignes concernées, et vous dit
-- combien il y en a — à vous de les reclasser d'abord.
--
-- DO $$
-- DECLARE n INTEGER;
-- BEGIN
--   SELECT count(*) INTO n FROM public.daily_expenses
--    WHERE category = 'achat_vrac';
--   IF n > 0 THEN
--     RAISE EXCEPTION
--       '% dépense(s) en catégorie achat_vrac — reclassez-les avant de '
--       'resserrer la contrainte (UPDATE public.daily_expenses SET '
--       'category = ''achat_marche'' WHERE category = ''achat_vrac'';)', n;
--   END IF;
--   ALTER TABLE public.daily_expenses
--     DROP CONSTRAINT IF EXISTS daily_expenses_category_check;
--   ALTER TABLE public.daily_expenses
--     ADD CONSTRAINT daily_expenses_category_check CHECK (category IN (
--       'achat_marche','electricite','gaz','eau','transport','entretien',
--       'personnel','consigne_rendue','autre'));
-- END $$;

-- ── Vérification ───────────────────────────────────────────────────────────
--   -- Plus rien de hotfix_151 ne subsiste :
--   SELECT to_regclass('public.inventory_snapshots') AS table_photos;   -- NULL
--   SELECT count(*) AS colonne_coef FROM information_schema.columns
--    WHERE table_name = 'products' AND column_name = 'shared_cost_coef'; -- 0
--
--   -- hotfix_152 est INTACT (méthode actuelle) :
--   SELECT column_name FROM information_schema.columns
--    WHERE (table_name = 'recipe_ingredients' AND column_name = 'portion_weight')
--       OR (table_name = 'daily_expenses'     AND column_name = 'ingredient_id');
--   -- doit renvoyer DEUX lignes.
--
-- Fin — hotfix_153_revert_marge_reelle.sql
