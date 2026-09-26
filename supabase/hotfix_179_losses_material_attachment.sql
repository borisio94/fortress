-- hotfix_179_losses_material_attachment.sql
-- ═════════════════════════════════════════════════════════════════════════
-- PERTES DE MATIÈRE — rattachement à des assiettes ou à un ingrédient.
--
-- Audit des marges restaurant, lot 1, décision n°2 (voie b) : une perte de
-- matière est RETIRÉE de l'assiette à répartir au lieu de s'ajouter à des
-- achats déjà entièrement imputés aux plats vendus (double comptage).
-- Pour la retirer, le bilan doit savoir CE qui a été perdu :
--
--   items          assiettes perdues, [{"product_id": "...", "quantity": 2}]
--                  → comptées comme des parts dans la répartition
--   ingredient_id  ingrédient manquant à l'inventaire (`ig_…`)
--                  → montant retiré des achats de cet ingrédient, plafonné
--
-- Une perte sans rattachement (casse de vaisselle, matériel…) reste une
-- charge ordinaire : `items` vide et `ingredient_id` NULL.
--
-- Référence logique, sans FK — convention de hotfix_140 : une FK ferait
-- rejeter en boucle les upserts d'une perte dont l'ingrédient n'est pas
-- encore synchronisé (offline-first).
--
-- ⚠ CE FICHIER S'APPLIQUE AVANT LE DÉPLOIEMENT DU CLIENT.
-- `Loss.toMap` envoie ces deux clés : sans les colonnes, Supabase rejette
-- l'upsert (PGRST204) et l'opération est abandonnée après dix essais, sans
-- bruit — la perte n'existerait que sur l'appareil qui l'a saisie.
--
-- ADD COLUMN avec défaut constant : métadonnée seule depuis Postgres 11,
-- aucune réécriture de table, verrou bref. 100 % idempotent.
-- ═════════════════════════════════════════════════════════════════════════

ALTER TABLE public.losses
  ADD COLUMN IF NOT EXISTS items jsonb NOT NULL DEFAULT '[]'::jsonb;

ALTER TABLE public.losses
  ADD COLUMN IF NOT EXISTS ingredient_id text;

-- `items` doit rester un TABLEAU : un objet ou un scalaire ferait lire au
-- client zéro assiette, et la perte redeviendrait une charge en silence.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'losses_items_is_array'
      AND conrelid = 'public.losses'::regclass
  ) THEN
    ALTER TABLE public.losses
      ADD CONSTRAINT losses_items_is_array
      CHECK (jsonb_typeof(items) = 'array');
  END IF;
END $$;

COMMENT ON COLUMN public.losses.items IS
  'Assiettes perdues [{product_id, quantity}] — comptées comme parts dans la '
  'répartition du coût matières (hotfix_179).';
COMMENT ON COLUMN public.losses.ingredient_id IS
  'Ingrédient (ig_…) dont un manque d''inventaire est retiré des achats de la '
  'période, plafonné (hotfix_179). Référence logique, sans FK.';

-- ── Contrôle ──────────────────────────────────────────────────────────────
-- Attendu : 2 lignes (items jsonb NOT NULL, ingredient_id text NULL).
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'losses'
  AND column_name IN ('items', 'ingredient_id')
ORDER BY column_name;
