-- ═══════════════════════════════════════════════════════════════════════════
-- Fortress — Hotfix 013 : Migration variantes — 4 champs stock
--
-- Les variantes sont stockées en JSONB dans products.variants.
-- Ce script migre chaque variante pour renommer stock_qty → stock_available
-- et ajouter stock_ordered, stock_physical, stock_blocked.
--
-- Rétrocompatible : si stock_available existe déjà, ne pas écraser.
--
-- Action : coller dans Supabase → SQL Editor → Run.
-- ═══════════════════════════════════════════════════════════════════════════

UPDATE products
SET variants = (
  SELECT jsonb_agg(
    CASE
      -- Si déjà migré (stock_available existe), ne pas toucher
      WHEN v ? 'stock_available' THEN v
      ELSE
        v
        -- Copier stock_qty vers stock_available
        || jsonb_build_object(
          'stock_available', COALESCE((v->>'stock_qty')::int, 0),
          'stock_physical',  COALESCE((v->>'stock_qty')::int, 0),
          'stock_ordered',   0,
          'stock_blocked',   0
        )
    END
  )
  FROM jsonb_array_elements(variants) AS v
)
WHERE variants IS NOT NULL
  AND jsonb_array_length(variants) > 0;
