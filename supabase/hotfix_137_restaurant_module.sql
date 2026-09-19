-- hotfix_137_restaurant_module.sql
-- ═════════════════════════════════════════════════════════════════════════
-- MODULE RESTAURANT — PR-1 : socle de données.
--   * restaurant_tables : plan de salle (table = numéro, capacité, statut).
--   * menu_modifiers    : groupes d'options par produit (cuisson, sup…).
--   * orders            : colonnes restauration (table, couverts, cuisine).
--
-- Choix d'implémentation (écarts ASSUMÉS vs la spec d'origine) :
--   * PAS de colonne `shops.shop_type` : la colonne `shops.sector` existe
--     déjà et porte déjà la valeur 'restaurant'. On étend simplement le jeu
--     de valeurs applicatif avec 'fastfood' et 'mixed' (colonne TEXT libre,
--     sans CHECK en base — cohérent avec l'existant). Une seule source de
--     vérité, aucune migration de données.
--   * PK en TEXT (id généré côté client `rt_`/`mm_` + microsecondes) au lieu
--     d'UUID : indispensable pour la création offline-first (Hive et Supabase
--     partagent la clé). Même choix que hotfix_127 / partner_ledger_entries.
--   * `orders.table_id` sans FK vers restaurant_tables : une table supprimée
--     ne doit jamais casser l'historique des commandes (le nom de table est
--     de toute façon re-résolu à l'affichage). Cohérent avec l'absence de FK
--     sur products.category_id.
--   * Les colonnes `orders` sont créées ici mais ne seront câblées côté Dart
--     qu'en PR-2 (Sale + saveOrder + syncOrders + _onOrderChange). Les créer
--     dès maintenant est inoffensif : elles ont toutes un défaut.
--
-- 100 % idempotent.
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

-- ── Tables ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.restaurant_tables (
  id               TEXT PRIMARY KEY,
  shop_id          TEXT NOT NULL
                     REFERENCES public.shops(id) ON DELETE CASCADE,
  number           INTEGER NOT NULL,
  name             TEXT    NOT NULL,
  capacity         INTEGER NOT NULL DEFAULT 4,
  status           TEXT    NOT NULL DEFAULT 'libre'
                     CHECK (status IN ('libre','occupee','addition','reservee')),
  covers           INTEGER,
  current_order_id TEXT,
  opened_at        TIMESTAMPTZ,
  reservation_time TIMESTAMPTZ,
  reservation_name TEXT,
  schema_version   INTEGER,
  created_at       TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.menu_modifiers (
  id             TEXT PRIMARY KEY,
  shop_id        TEXT NOT NULL
                   REFERENCES public.shops(id) ON DELETE CASCADE,
  product_id     TEXT,
  name           TEXT    NOT NULL,
  options        JSONB   NOT NULL DEFAULT '[]'::jsonb,
  price_impact   INTEGER NOT NULL DEFAULT 0,
  schema_version INTEGER,
  created_at     TIMESTAMPTZ DEFAULT now()
);

-- Un même numéro de table ne peut pas exister deux fois dans une boutique.
CREATE UNIQUE INDEX IF NOT EXISTS restaurant_tables_shop_number_uidx
  ON public.restaurant_tables(shop_id, number);
CREATE INDEX IF NOT EXISTS restaurant_tables_shop_idx
  ON public.restaurant_tables(shop_id);
CREATE INDEX IF NOT EXISTS menu_modifiers_shop_idx
  ON public.menu_modifiers(shop_id);
CREATE INDEX IF NOT EXISTS menu_modifiers_product_idx
  ON public.menu_modifiers(product_id);

-- ── Colonnes restauration sur orders (câblage Dart en PR-2) ───────────────
ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS table_id        TEXT,
  ADD COLUMN IF NOT EXISTS covers          INTEGER,
  ADD COLUMN IF NOT EXISTS order_type      TEXT NOT NULL DEFAULT 'takeaway',
  ADD COLUMN IF NOT EXISTS sent_to_kitchen BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS kitchen_ready   BOOLEAN NOT NULL DEFAULT false;

-- CHECK ajouté séparément : ADD COLUMN IF NOT EXISTS ne rejoue pas la
-- contrainte si la colonne préexiste (ré-application du script).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'orders_order_type_check'
       AND conrelid = 'public.orders'::regclass
  ) THEN
    ALTER TABLE public.orders
      ADD CONSTRAINT orders_order_type_check
      CHECK (order_type IN ('dine_in','takeaway','delivery'));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS orders_kitchen_idx
  ON public.orders(shop_id, sent_to_kitchen, kitchen_ready)
  WHERE sent_to_kitchen = true;

-- ── RLS : membres / owner / super-admin (lecture + écriture) ──────────────
ALTER TABLE public.restaurant_tables ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.menu_modifiers    ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS restaurant_tables_members ON public.restaurant_tables;
CREATE POLICY restaurant_tables_members
  ON public.restaurant_tables
  FOR ALL TO authenticated
  USING      (public._is_shop_member(shop_id))
  WITH CHECK (public._is_shop_member(shop_id));

DROP POLICY IF EXISTS menu_modifiers_members ON public.menu_modifiers;
CREATE POLICY menu_modifiers_members
  ON public.menu_modifiers
  FOR ALL TO authenticated
  USING      (public._is_shop_member(shop_id))
  WITH CHECK (public._is_shop_member(shop_id));

-- ── Realtime : sans ça, le plan de salle ne se met pas à jour entre les
--    appareils (tablette salle ↔ téléphone serveur). Obligatoire.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
     WHERE pubname = 'supabase_realtime'
       AND schemaname = 'public'
       AND tablename  = 'restaurant_tables'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.restaurant_tables;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
     WHERE pubname = 'supabase_realtime'
       AND schemaname = 'public'
       AND tablename  = 'menu_modifiers'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.menu_modifiers;
  END IF;
END $$;

-- ── Vérification ──────────────────────────────────────────────────────────
--   SELECT tablename, rowsecurity FROM pg_tables
--    WHERE schemaname='public'
--      AND tablename IN ('restaurant_tables','menu_modifiers');
--   SELECT column_name, data_type, column_default
--     FROM information_schema.columns
--    WHERE table_name='orders'
--      AND column_name IN ('table_id','covers','order_type',
--                          'sent_to_kitchen','kitchen_ready');
--   SELECT tablename FROM pg_publication_tables
--    WHERE pubname='supabase_realtime' AND tablename LIKE '%restaurant%';
--
-- Fin — hotfix_137_restaurant_module.sql
