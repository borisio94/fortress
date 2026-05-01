-- =============================================================================
-- 015 — Row version clock pour détection d'événements realtime stales
--
-- Problème : Supabase ne garantit pas l'ordre d'arrivée des événements
-- realtime pour des écritures rapprochées sur la même ligne. Une fenêtre
-- temporelle (10s) est aujourd'hui utilisée côté Flutter pour ignorer les
-- échos récents, mais elle est fragile : un event qui arrive après la
-- fenêtre peut écraser un état plus récent.
--
-- Cas reproduit : vente multi-variantes (A puis B sur le même produit) →
-- l'event de l'upsert A (snapshot B encore à 5) arrive après le débit
-- local de B et remet B à 5 → -1 unité au lieu de -2.
--
-- Solution : chaque UPDATE incrémente une colonne `row_version` (via
-- trigger SQL). Côté Flutter, à la réception d'un event, on compare
-- `payload.new.row_version` à la version stockée localement et on
-- ignore l'event si la version remote n'est pas strictement supérieure.
-- Pas de race condition possible peu importe le timing.
--
-- Tables concernées :
--   - products       (le plus critique : multi-variantes)
--   - stock_levels   (par-variante × emplacement)
--   - orders         (commandes)
--
-- Idempotente.
-- =============================================================================

-- ── 1. Fonction trigger générique ────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.bump_row_version()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $bump$
BEGIN
  -- Sur UPDATE : OLD.row_version + 1
  -- Sur INSERT : démarre à 0 (default de la colonne) — pas géré ici
  NEW.row_version := COALESCE(OLD.row_version, 0) + 1;
  RETURN NEW;
END $bump$;

-- ── 2. products ──────────────────────────────────────────────────────────
DO $apply_products$
BEGIN
  ALTER TABLE public.products
    ADD COLUMN IF NOT EXISTS row_version BIGINT NOT NULL DEFAULT 0;
EXCEPTION WHEN undefined_table THEN NULL;
END $apply_products$;

DROP TRIGGER IF EXISTS trg_products_row_version ON public.products;
DO $trg_products$
BEGIN
  CREATE TRIGGER trg_products_row_version
  BEFORE UPDATE ON public.products
  FOR EACH ROW EXECUTE FUNCTION public.bump_row_version();
EXCEPTION WHEN undefined_table THEN NULL;
END $trg_products$;

-- ── 3. stock_levels ──────────────────────────────────────────────────────
DO $apply_levels$
BEGIN
  ALTER TABLE public.stock_levels
    ADD COLUMN IF NOT EXISTS row_version BIGINT NOT NULL DEFAULT 0;
EXCEPTION WHEN undefined_table THEN NULL;
END $apply_levels$;

DROP TRIGGER IF EXISTS trg_stock_levels_row_version ON public.stock_levels;
DO $trg_levels$
BEGIN
  CREATE TRIGGER trg_stock_levels_row_version
  BEFORE UPDATE ON public.stock_levels
  FOR EACH ROW EXECUTE FUNCTION public.bump_row_version();
EXCEPTION WHEN undefined_table THEN NULL;
END $trg_levels$;

-- ── 4. orders ────────────────────────────────────────────────────────────
DO $apply_orders$
BEGIN
  ALTER TABLE public.orders
    ADD COLUMN IF NOT EXISTS row_version BIGINT NOT NULL DEFAULT 0;
EXCEPTION WHEN undefined_table THEN NULL;
END $apply_orders$;

DROP TRIGGER IF EXISTS trg_orders_row_version ON public.orders;
DO $trg_orders$
BEGIN
  CREATE TRIGGER trg_orders_row_version
  BEFORE UPDATE ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.bump_row_version();
EXCEPTION WHEN undefined_table THEN NULL;
END $trg_orders$;

-- ── Vérification après application ───────────────────────────────────────
-- SELECT column_name, data_type, column_default
--   FROM information_schema.columns
--  WHERE table_schema='public' AND column_name='row_version';
-- → 3 lignes attendues (products, stock_levels, orders)
--
-- Test :
--   UPDATE products SET name = name WHERE id = 'TEST_ID' RETURNING row_version;
--   → row_version doit s'incrémenter de 1 à chaque exécution.
