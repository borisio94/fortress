-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_119_purge_bypass_stock_guard.sql
--
-- Suite de hotfix_118_fix_block_product_delete_raise.sql.
--
-- Bug visible (après le fix 118) : « Supprimer le compte » d'un owner échoue
-- désormais avec :
--   PostgrestException(message: produit_en_stock : stock=5/5, ventes
--                      ouvertes=0, code: P0001, ...)
--
-- Cause :
--   delete_user_account → _purge_shop_dependents fait `DELETE FROM products`
--   (niveau 4). Ce DELETE déclenche le trigger BEFORE DELETE
--   `block_product_delete_with_stock` (hotfix_083), qui REFUSE la suppression
--   d'un produit ayant encore du stock résiduel. Or `_purge_shop_dependents`
--   ne vide pas toujours `stock_levels` avant les produits (stock à un
--   emplacement dont la suppression ne cascade pas, ou `stock_levels` sans
--   colonne `shop_id` → DELETE niveau 3 silencieusement sans effet). Le stock
--   survit jusqu'au niveau 4 → le garde-fou bloque → toute la purge rollback.
--
--   Ce garde-fou est légitime pour une suppression INTERACTIVE (on protège
--   l'historique / le stock), mais pas pendant une purge complète de compte
--   ou un reset : là, on supprime TOUT le shop dans la même transaction, le
--   stock résiduel n'a plus de sens.
--
-- Correctif :
--   Le trigger respecte désormais deux flags de session « purge en cours » :
--     • `app.bypass_owner_protection` — posé par delete_user_account
--       (hotfix_098) lors de la suppression d'un compte. Même flag que le
--       trigger protect_owner_delete (hotfix_036).
--     • `app.bypass_stock_guard` — flag DÉDIÉ au garde-fou stock, posé par
--       reset_shop_data / reset_all_data (hotfix_120). Volontairement
--       distinct : il ne touche PAS la protection owner (un reset de boutique
--       conserve le membership du propriétaire).
--   Ces flags sont transaction-local et restent visibles dans les triggers
--   déclenchés à l'intérieur de _purge_shop_dependents — exactement comme
--   protect_owner_delete l'exploite déjà. Si l'un vaut 'on', le garde-fou
--   stock laisse passer.
--
--   Aucune incidence sur les suppressions normales : ces flags ne sont JAMAIS
--   posés hors purge/reset, donc le garde-fou reste pleinement actif pour les
--   suppressions interactives et la RPC delete_product.
--
-- Conserve le RAISE corrigé du hotfix_118 (motif sûr, pas de 42601).
-- Idempotent : CREATE OR REPLACE de la seule fonction (le trigger pointe
-- déjà dessus). Aucune autre fonction touchée.
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
  -- Purge privilégiée (suppression de compte / reset) : la même transaction
  -- supprime massivement et se signale via un flag de session — soit
  -- `app.bypass_owner_protection` (delete_user_account, cf. hotfix_036/098),
  -- soit `app.bypass_stock_guard` (reset_shop_data/reset_all_data, hotfix_120).
  -- Le garde-fou stock n'a alors pas lieu d'être — on laisse passer.
  IF current_setting('app.bypass_owner_protection', true) = 'on'
     OR current_setting('app.bypass_stock_guard', true) = 'on' THEN
    RETURN OLD;
  END IF;

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
