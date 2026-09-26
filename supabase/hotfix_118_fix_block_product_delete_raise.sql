-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_118_fix_block_product_delete_raise.sql
--
-- Bug visible : depuis le panneau super-admin, « Supprimer le compte » d'un
-- owner de boutique échoue avec :
--   PostgrestException(message: RAISE option already specified: MESSAGE,
--                      code: 42601, details: , hint: null)
-- et RIEN n'est supprimé (la transaction est annulée).
--
-- Cause :
--   delete_user_account → _purge_shop_dependents fait, au niveau 4, un
--   `DELETE FROM products` (hard delete). Ce DELETE déclenche le trigger
--   BEFORE DELETE `trg_block_product_delete_with_stock` (hotfix_083).
--   La fonction `block_product_delete_with_stock()` contient un RAISE mal
--   formé :
--
--       RAISE EXCEPTION 'produit_en_stock'
--         USING ERRCODE = 'P0001',
--               MESSAGE = format(...);     -- ← 42601
--
--   Quand une chaîne de format suit `RAISE EXCEPTION`, Postgres la prend
--   comme MESSAGE. Le `USING MESSAGE = …` redéfinit alors MESSAGE une 2e
--   fois → « RAISE option already specified: MESSAGE » (SQLSTATE 42601).
--   C'est une erreur de COMPILATION de la fonction : elle survient au
--   premier hard-DELETE de produit de la session, AVANT même d'évaluer le
--   `IF` — donc même si le stock a déjà été purgé.
--
--   En usage normal l'app fait du SOFT-delete (hotfix_085), donc ce trigger
--   BEFORE DELETE ne se déclenche jamais et le bug restait invisible. La
--   purge du owner est le premier vrai hard-DELETE → le bug se révèle.
--
--   C'est exactement le piège déjà documenté et corrigé dans hotfix_081
--   (transitions de statut des commandes).
--
-- Correctif :
--   Réécriture du RAISE selon le motif SÛR (pas de chaîne de format devant
--   `USING`, le code lisible `produit_en_stock` est préfixé dans MESSAGE).
--   Comportement et DETAIL JSON strictement identiques par ailleurs ; la
--   logique métier du trigger (blocage si stock résiduel ou ventes ouvertes)
--   est inchangée. Au moment de la purge owner, stock_levels et orders sont
--   déjà supprimés (niveau 3 de _purge_shop_dependents) → le `IF` est faux
--   → le DELETE FROM products passe.
--
-- Idempotent : CREATE OR REPLACE de la seule fonction (le trigger pointe
-- déjà dessus, aucun DROP TRIGGER nécessaire). Aucune autre fonction touchée.
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.block_product_delete_with_stock()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_variant_ids   text[] := ARRAY[]::text[];
  v_total_avail   integer := 0;
  v_total_phys    integer := 0;
  v_open_sales    integer := 0;
BEGIN
  -- Extraction des variant_ids depuis le JSONB.
  SELECT COALESCE(
    array_agg(DISTINCT (v->>'id'))
      FILTER (WHERE (v->>'id') IS NOT NULL AND length(v->>'id') > 0),
    ARRAY[]::text[]
  )
  INTO v_variant_ids
  FROM jsonb_array_elements(COALESCE(OLD.variants, '[]'::jsonb)) AS v;

  -- 1. Stock résiduel via stock_levels (location-agnostique).
  IF array_length(v_variant_ids, 1) > 0 THEN
    SELECT
      COALESCE(SUM(stock_available), 0),
      COALESCE(SUM(stock_physical),  0)
    INTO v_total_avail, v_total_phys
    FROM public.stock_levels
    WHERE variant_id = ANY(v_variant_ids);
  END IF;

  -- 2. Ventes ouvertes (scheduled / processing) référencant le produit
  --    OU une de ses variantes via items JSONB.
  SELECT count(*)
  INTO v_open_sales
  FROM public.orders o,
       LATERAL jsonb_array_elements(COALESCE(o.items, '[]'::jsonb)) AS it
  WHERE o.status IN ('scheduled', 'processing')
    AND (it->>'product_id' = OLD.id::text
         OR (it->>'product_id' = ANY(v_variant_ids)));

  IF v_total_avail > 0 OR v_total_phys > 0 OR v_open_sales > 0 THEN
    -- ATTENTION : ne PAS mettre de chaîne de format derrière RAISE EXCEPTION
    -- quand on passe `USING MESSAGE = ...` — Postgres l'interprète comme un
    -- MESSAGE par défaut et le `USING MESSAGE` devient une DEUXIÈME
    -- définition → 42601 « RAISE option already specified » (cf. hotfix_081).
    -- Le code lisible `produit_en_stock` est préfixé dans le MESSAGE.
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = format(
                  'produit_en_stock : stock=%s/%s, ventes ouvertes=%s',
                  v_total_avail, v_total_phys, v_open_sales),
      DETAIL  = jsonb_build_object(
                  'code',             'produit_en_stock',
                  'product_id',       OLD.id::text,
                  'product_name',     OLD.name,
                  'total_available',  v_total_avail,
                  'total_physical',   v_total_phys,
                  'open_sales_count', v_open_sales)::text;
  END IF;

  RETURN OLD;
END;
$fn$;

NOTIFY pgrst, 'reload schema';
