-- hotfix_140_restaurant_finances.sql
-- ═════════════════════════════════════════════════════════════════════════
-- MODULE FINANCES RESTAURANT — socle de données COMPLET (modules 1 à 7).
--
-- Crée les 8 tables du module finances restaurant en une seule fois. Seules
-- `ingredients` et `recipe_ingredients` sont câblées côté Dart en PR-A ; les
-- 6 autres (restaurant_activities, stock_items, fixed_charges, losses,
-- employees, payroll) sont créées dès maintenant et restent VIDES tant que
-- leur PR n'est pas livrée — sans aucun impact sur l'existant (toutes leurs
-- colonnes ont un défaut, et rien ne les lit encore).
--
-- Conventions (alignées sur hotfix_137_restaurant_module) :
--   * PK en TEXT, id généré côté client (ig_ · ri_ · ra_ · si_ · fc_ · ls_ ·
--     em_ · pr_ + microsecondes) → offline-first (Hive et Supabase partagent
--     la clé). Même choix que hotfix_127 / _137 / partner_ledger_entries.
--   * `shop_id` TEXT NOT NULL REFERENCES shops(id) ON DELETE CASCADE — la
--     boutique est toujours synchronisée avant ses données, la FK est sûre et
--     nettoie en cascade à la suppression d'une boutique.
--   * `schema_version` INTEGER — les entités Dart écrivent ce champ (cf.
--     SchemaMigrator), la colonne doit exister.
--   * RLS : membres / owner / super-admin via public._is_shop_member(shop_id)
--     (helper de hotfix_041). SANS ces policies, la synchro renvoie
--     « permission denied » → upserts « Abandoned after 10 retries ».
--   * Realtime : chaque table est ajoutée à la publication supabase_realtime
--     (sync inter-appareils). Idempotent.
--
-- ÉCART ASSUMÉ vs la spec du prompt — PAS de FK inter-entités
--   (`recipe_ingredients.product_id`/`ingredient_id`, `stock_items.activity_id`,
--    `payroll.employee_id`). En offline-first, l'ordre d'arrivée des upserts
--   dans la file n'est pas garanti : une ligne enfant poussée AVANT son parent
--   violerait la FK et l'op serait abandonnée après 10 essais (bug vécu sur
--   `products.track_stock`). Même raison que l'absence de FK sur
--   `orders.table_id` (hotfix_137) et `products.category_id`. L'intégrité est
--   assurée côté application (les ids sont créés ensemble, même écran).
--
-- 100 % idempotent (ré-exécutable sans effet de bord).
-- ═════════════════════════════════════════════════════════════════════════

-- Garde-fou : la RLS dépend du helper de hotfix_041.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc
     WHERE proname = '_is_shop_member'
       AND pronamespace = 'public'::regnamespace
  ) THEN
    RAISE EXCEPTION
      'public._is_shop_member() manquante — appliquer hotfix_041 d''abord.';
  END IF;
END $$;

-- ══════════════════════════════════════════════════════════════════════════
-- 1. INGRÉDIENTS (module 1) — catalogue d'ingrédients (spécialisé / partagé).
-- ══════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.ingredients (
  id              TEXT PRIMARY KEY,
  shop_id         TEXT NOT NULL
                    REFERENCES public.shops(id) ON DELETE CASCADE,
  name            TEXT    NOT NULL,
  unit            TEXT    NOT NULL DEFAULT 'pièce',
  quantity        FLOAT   DEFAULT 0,
  alert_threshold FLOAT   DEFAULT 0,
  cost_per_unit   INTEGER DEFAULT 0,
  type            TEXT    DEFAULT 'specialized'
                    CHECK (type IN ('specialized','shared')),
  schema_version  INTEGER,
  created_at      TIMESTAMPTZ DEFAULT now()
);

-- Lignes de fiche recette : (produit ↔ ingrédient, quantité). Sans FK inter-
-- entités (cf. en-tête) — product_id / ingredient_id sont des refs logiques.
CREATE TABLE IF NOT EXISTS public.recipe_ingredients (
  id             TEXT PRIMARY KEY,
  shop_id        TEXT NOT NULL
                   REFERENCES public.shops(id) ON DELETE CASCADE,
  product_id     TEXT  NOT NULL,
  ingredient_id  TEXT  NOT NULL,
  quantity       FLOAT NOT NULL,
  unit           TEXT  NOT NULL,
  schema_version INTEGER,
  created_at     TIMESTAMPTZ DEFAULT now()
);

-- ══════════════════════════════════════════════════════════════════════════
-- 3. ACTIVITÉS CONNEXES (module 3) — mode stock / mode recette. [PR-B]
-- ══════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.restaurant_activities (
  id              TEXT PRIMARY KEY,
  shop_id         TEXT NOT NULL
                    REFERENCES public.shops(id) ON DELETE CASCADE,
  name            TEXT    NOT NULL,
  mode            TEXT    NOT NULL CHECK (mode IN ('stock','recipe')),
  track_stock     BOOLEAN DEFAULT true,
  stock_threshold INTEGER DEFAULT 0,
  schema_version  INTEGER,
  created_at      TIMESTAMPTZ DEFAULT now()
);

-- ══════════════════════════════════════════════════════════════════════════
-- 4. ARTICLES SANS TRANSFORMATION (module 4) — boissons, emballages… [PR-B]
-- ══════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.stock_items (
  id             TEXT PRIMARY KEY,
  shop_id        TEXT NOT NULL
                   REFERENCES public.shops(id) ON DELETE CASCADE,
  name           TEXT    NOT NULL,
  unit           TEXT    NOT NULL,
  quantity       FLOAT   DEFAULT 0,
  min_quantity   FLOAT   DEFAULT 0,
  cost_per_unit  INTEGER DEFAULT 0,
  selling_price  INTEGER DEFAULT 0,
  activity_id    TEXT,            -- ref logique vers restaurant_activities (pas de FK)
  schema_version INTEGER,
  created_at     TIMESTAMPTZ DEFAULT now()
);

-- ══════════════════════════════════════════════════════════════════════════
-- 5. DÉPENSES FIXES ET CHARGES (module 5) — échéances récurrentes. [PR-C]
-- ══════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.fixed_charges (
  id                TEXT PRIMARY KEY,
  shop_id           TEXT NOT NULL
                      REFERENCES public.shops(id) ON DELETE CASCADE,
  name              TEXT    NOT NULL,
  amount            INTEGER NOT NULL,
  frequency         TEXT    NOT NULL
                      CHECK (frequency IN ('monthly','quarterly','yearly','once')),
  next_due_date     DATE    NOT NULL,
  alert_days_before INTEGER DEFAULT 7,
  category          TEXT    DEFAULT 'autre'
                      CHECK (category IN (
                        'loyer','electricite','internet',
                        'impots','salaires','autre')),
  paid_dates        JSONB   DEFAULT '[]'::jsonb,
  schema_version    INTEGER,
  created_at        TIMESTAMPTZ DEFAULT now()
);

-- ══════════════════════════════════════════════════════════════════════════
-- 6. DÉCLARATION DES PERTES (module 6) — casse, invendus, non payés… [PR-C]
-- ══════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.losses (
  id             TEXT PRIMARY KEY,
  shop_id        TEXT NOT NULL
                   REFERENCES public.shops(id) ON DELETE CASCADE,
  description    TEXT    NOT NULL,
  amount         INTEGER NOT NULL,
  category       TEXT    NOT NULL CHECK (category IN (
                   'casse','reste_invendu','plat_mal_fait',
                   'non_paye','materiel_endommage','autre')),
  origin         TEXT    NOT NULL,
  date           DATE    NOT NULL DEFAULT CURRENT_DATE,
  declared_by    TEXT,
  schema_version INTEGER,
  created_at     TIMESTAMPTZ DEFAULT now()
);

-- ══════════════════════════════════════════════════════════════════════════
-- 7. EMPLOYÉS ET PAIE (module 7). [PR-D]
-- ══════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.employees (
  id             TEXT PRIMARY KEY,
  shop_id        TEXT NOT NULL
                   REFERENCES public.shops(id) ON DELETE CASCADE,
  full_name      TEXT    NOT NULL,
  role           TEXT    NOT NULL,
  base_salary    INTEGER NOT NULL,
  hire_date      DATE    NOT NULL,
  phone          TEXT,
  is_active      BOOLEAN DEFAULT true,
  schema_version INTEGER,
  created_at     TIMESTAMPTZ DEFAULT now()
);

-- payroll.employee_id : ref logique vers employees (pas de FK, cf. en-tête).
CREATE TABLE IF NOT EXISTS public.payroll (
  id             TEXT PRIMARY KEY,
  shop_id        TEXT NOT NULL
                   REFERENCES public.shops(id) ON DELETE CASCADE,
  employee_id    TEXT    NOT NULL,
  month          TEXT    NOT NULL,
  base_salary    INTEGER NOT NULL,
  bonuses        INTEGER DEFAULT 0,
  deductions     INTEGER DEFAULT 0,
  net_salary     INTEGER NOT NULL,
  paid_at        TIMESTAMPTZ,
  notes          TEXT,
  schema_version INTEGER,
  created_at     TIMESTAMPTZ DEFAULT now()
);

-- ── Index (filtre par boutique + jointures logiques fréquentes) ────────────
CREATE INDEX IF NOT EXISTS ingredients_shop_idx           ON public.ingredients(shop_id);
CREATE INDEX IF NOT EXISTS recipe_ingredients_shop_idx    ON public.recipe_ingredients(shop_id);
CREATE INDEX IF NOT EXISTS recipe_ingredients_product_idx ON public.recipe_ingredients(product_id);
CREATE INDEX IF NOT EXISTS recipe_ingredients_ing_idx     ON public.recipe_ingredients(ingredient_id);
CREATE INDEX IF NOT EXISTS restaurant_activities_shop_idx ON public.restaurant_activities(shop_id);
CREATE INDEX IF NOT EXISTS stock_items_shop_idx           ON public.stock_items(shop_id);
CREATE INDEX IF NOT EXISTS stock_items_activity_idx       ON public.stock_items(activity_id);
CREATE INDEX IF NOT EXISTS fixed_charges_shop_idx         ON public.fixed_charges(shop_id);
CREATE INDEX IF NOT EXISTS fixed_charges_due_idx          ON public.fixed_charges(shop_id, next_due_date);
CREATE INDEX IF NOT EXISTS losses_shop_idx                ON public.losses(shop_id);
CREATE INDEX IF NOT EXISTS losses_date_idx                ON public.losses(shop_id, date);
CREATE INDEX IF NOT EXISTS employees_shop_idx             ON public.employees(shop_id);
CREATE INDEX IF NOT EXISTS payroll_shop_idx               ON public.payroll(shop_id);
CREATE INDEX IF NOT EXISTS payroll_employee_idx           ON public.payroll(employee_id);

-- ── RLS : membres / owner / super-admin (lecture + écriture) ───────────────
DO $$
DECLARE
  t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'ingredients','recipe_ingredients','restaurant_activities','stock_items',
    'fixed_charges','losses','employees','payroll'
  ] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY;', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I;', t || '_members', t);
    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR ALL TO authenticated '
      'USING (public._is_shop_member(shop_id)) '
      'WITH CHECK (public._is_shop_member(shop_id));',
      t || '_members', t);
  END LOOP;
END $$;

-- ── Realtime : sync inter-appareils (obligatoire pour la synchro live) ─────
DO $$
DECLARE
  t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'ingredients','recipe_ingredients','restaurant_activities','stock_items',
    'fixed_charges','losses','employees','payroll'
  ] LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_publication_tables
       WHERE pubname = 'supabase_realtime'
         AND schemaname = 'public'
         AND tablename  = t
    ) THEN
      EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I;', t);
    END IF;
  END LOOP;
END $$;

-- ── Vérification ───────────────────────────────────────────────────────────
--   -- Les 8 tables existent avec RLS activée :
--   SELECT tablename, rowsecurity FROM pg_tables
--    WHERE schemaname='public' AND tablename IN (
--      'ingredients','recipe_ingredients','restaurant_activities','stock_items',
--      'fixed_charges','losses','employees','payroll') ORDER BY tablename;
--   -- Les policies membres sont posées :
--   SELECT tablename, policyname FROM pg_policies
--    WHERE schemaname='public' AND policyname LIKE '%_members'
--      AND tablename IN ('ingredients','recipe_ingredients','restaurant_activities',
--      'stock_items','fixed_charges','losses','employees','payroll');
--   -- Realtime :
--   SELECT tablename FROM pg_publication_tables
--    WHERE pubname='supabase_realtime' AND tablename IN (
--      'ingredients','recipe_ingredients','restaurant_activities','stock_items',
--      'fixed_charges','losses','employees','payroll');
--
-- Fin — hotfix_140_restaurant_finances.sql
