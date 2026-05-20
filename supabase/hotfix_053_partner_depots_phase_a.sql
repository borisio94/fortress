-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_053_partner_depots_phase_a.sql
--
-- Phase A de la promotion des partenaires en boutiques satellites.
-- Cette phase est NON DESTRUCTIVE — elle ne fait qu'ajouter des colonnes
-- nullable et une nouvelle table. Aucune donnée existante n'est modifiée.
--
-- Objet :
--   1. Ajouter `shops.kind` ∈ {'main','partner_depot'} (défaut 'main')
--      pour distinguer les boutiques principales des dépôts partenaires.
--   2. Ajouter `shops.parent_shop_id` qui pointe la boutique principale
--      dont un partner_depot dépend (catalogue source-of-truth).
--   3. Créer la table `product_visibility` qui permet de masquer
--      explicitement un produit dans une boutique enfant. Comportement
--      par défaut (ligne absente) = visible.
--
-- Phase B (à venir, séparée) : convertir le partenaire existant
-- (StockLocation type='partner') en `shops kind='partner_depot'` via une
-- RPC dédiée, à déclencher manuellement avec un script de rollback prêt.
--
-- Idempotent : peut être rejoué sans effet de bord.
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1. shops.kind ─────────────────────────────────────────────────────────
ALTER TABLE shops
  ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'main';

-- Contrainte CHECK ajoutée séparément pour rester idempotent (pas de
-- "ADD CONSTRAINT IF NOT EXISTS" en PG standard).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'shops_kind_check'
       AND conrelid = 'public.shops'::regclass
  ) THEN
    ALTER TABLE public.shops
      ADD CONSTRAINT shops_kind_check
      CHECK (kind IN ('main', 'partner_depot'));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS shops_kind_idx ON shops(kind);

-- ── 2. shops.parent_shop_id ───────────────────────────────────────────────
-- Pour kind='partner_depot' → pointe la boutique principale (kind='main')
-- dont le catalogue est partagé. NULL pour kind='main'.
ALTER TABLE shops
  ADD COLUMN IF NOT EXISTS parent_shop_id text;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'shops_parent_shop_fk'
       AND conrelid = 'public.shops'::regclass
  ) THEN
    ALTER TABLE public.shops
      ADD CONSTRAINT shops_parent_shop_fk
      FOREIGN KEY (parent_shop_id)
      REFERENCES public.shops(id)
      ON DELETE RESTRICT;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS shops_parent_shop_idx ON shops(parent_shop_id);

-- Cohérence : un partner_depot doit avoir parent_shop_id non NULL,
-- une main ne doit pas en avoir. Géré applicativement pour l'instant —
-- on ajoutera un trigger en phase B si nécessaire.

-- ── 3. Table product_visibility ───────────────────────────────────────────
-- Sparse table : ligne absente = visible (comportement par défaut).
-- Ligne avec hidden=true → produit masqué dans la boutique enfant.
-- Permet aussi le pattern inverse (hidden=false explicite) pour évoluer
-- vers du opt-in si besoin futur.
CREATE TABLE IF NOT EXISTS product_visibility (
  product_id  text NOT NULL REFERENCES products(id)  ON DELETE CASCADE,
  shop_id     text NOT NULL REFERENCES shops(id)     ON DELETE CASCADE,
  hidden      boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (product_id, shop_id)
);

CREATE INDEX IF NOT EXISTS product_visibility_shop_idx
  ON product_visibility(shop_id);

-- ── 4. RLS sur product_visibility ─────────────────────────────────────────
ALTER TABLE product_visibility ENABLE ROW LEVEL SECURITY;

-- SELECT : membre de la boutique enfant (pour qu'il sache ce qui est masqué
-- chez lui) OU membre de la boutique source du produit (le catalogue).
DROP POLICY IF EXISTS product_visibility_select ON product_visibility;
CREATE POLICY product_visibility_select ON product_visibility
  FOR SELECT TO authenticated
  USING (
    public._is_shop_member(shop_id)
    OR EXISTS (
      SELECT 1 FROM products p
       WHERE p.id = product_id
         AND public._is_shop_member(p.store_id::text)
    )
  );

-- INSERT/UPDATE/DELETE : seul un membre de la boutique source (le catalogue)
-- peut décider de masquer un produit chez un enfant. Empêche un admin de
-- partner_depot de manipuler la visibilité.
DROP POLICY IF EXISTS product_visibility_insert ON product_visibility;
CREATE POLICY product_visibility_insert ON product_visibility
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM products p
       WHERE p.id = product_id
         AND public._is_shop_member(p.store_id::text)
    )
  );

DROP POLICY IF EXISTS product_visibility_update ON product_visibility;
CREATE POLICY product_visibility_update ON product_visibility
  FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM products p
       WHERE p.id = product_id
         AND public._is_shop_member(p.store_id::text)
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM products p
       WHERE p.id = product_id
         AND public._is_shop_member(p.store_id::text)
    )
  );

DROP POLICY IF EXISTS product_visibility_delete ON product_visibility;
CREATE POLICY product_visibility_delete ON product_visibility
  FOR DELETE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM products p
       WHERE p.id = product_id
         AND public._is_shop_member(p.store_id::text)
    )
  );

-- ── 5. Trigger updated_at ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._product_visibility_set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS product_visibility_updated_at ON product_visibility;
CREATE TRIGGER product_visibility_updated_at
  BEFORE UPDATE ON product_visibility
  FOR EACH ROW EXECUTE FUNCTION public._product_visibility_set_updated_at();

-- ════════════════════════════════════════════════════════════════════════════
-- Vérification post-exécution (à lancer manuellement après le RUN) :
--
--   SELECT column_name, data_type, column_default, is_nullable
--     FROM information_schema.columns
--    WHERE table_name = 'shops' AND column_name IN ('kind','parent_shop_id');
--
--   SELECT * FROM information_schema.tables WHERE table_name = 'product_visibility';
--
--   SELECT count(*) AS shops_main FROM shops WHERE kind = 'main';
--   -- Doit renvoyer le nombre total de tes boutiques actuelles
--   -- (toutes héritent de 'main' par défaut).
-- ════════════════════════════════════════════════════════════════════════════
