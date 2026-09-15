-- hotfix_127_delivery_zones_quartiers.sql
-- ═════════════════════════════════════════════════════════════════════════
-- Frais de livraison PAR QUARTIER (PR-1).
--   * delivery_zones     : regroupements nommés (Centre-ville, Banlieue…).
--   * delivery_quartiers : quartier (ville + nom + prix FCFA), rattaché
--                          optionnellement à une zone.
--
-- Choix d'implémentation :
--   * PK en TEXT (id généré côté client `dz_`/`dq_` + microsecondes) →
--     création offline-first immédiate (Hive ↔ Supabase partagent la clé),
--     cohérent avec partner_ledger_entries. (≠ UUID de la spec, assumé.)
--   * Colonne `schema_version` : l'entité Flutter l'envoie dans toMap().
--   * RLS membres/owner via le helper public._is_shop_member (hotfix_041).
--   * Lecture PUBLIQUE (catalogue web) via RPC SECURITY DEFINER filtrée par
--     shop_id (PAS de policy anon large → pas de fuite des tarifs des autres
--     boutiques ; même pattern que get_public_catalogue_products).
--
-- 100 % idempotent.
-- ═════════════════════════════════════════════════════════════════════════

-- Garde-fou : RLS dépend du helper de hotfix_041.
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
CREATE TABLE IF NOT EXISTS public.delivery_zones (
  id             TEXT PRIMARY KEY,
  shop_id        TEXT NOT NULL,
  name           TEXT NOT NULL,
  schema_version INTEGER,
  created_at     TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.delivery_quartiers (
  id             TEXT PRIMARY KEY,
  zone_id        TEXT REFERENCES public.delivery_zones(id) ON DELETE SET NULL,
  shop_id        TEXT NOT NULL,
  city           TEXT NOT NULL,
  name           TEXT NOT NULL,
  price          INTEGER NOT NULL DEFAULT 0,
  schema_version INTEGER,
  created_at     TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS delivery_zones_shop_idx
  ON public.delivery_zones(shop_id);
CREATE INDEX IF NOT EXISTS delivery_quartiers_shop_city_idx
  ON public.delivery_quartiers(shop_id, city);
CREATE INDEX IF NOT EXISTS delivery_quartiers_zone_idx
  ON public.delivery_quartiers(zone_id);

-- ── RLS : membres / owner / super-admin (lecture + écriture) ───────────────
ALTER TABLE public.delivery_zones     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.delivery_quartiers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS delivery_zones_members ON public.delivery_zones;
CREATE POLICY delivery_zones_members
  ON public.delivery_zones
  FOR ALL TO authenticated
  USING      (public._is_shop_member(shop_id))
  WITH CHECK (public._is_shop_member(shop_id));

DROP POLICY IF EXISTS delivery_quartiers_members ON public.delivery_quartiers;
CREATE POLICY delivery_quartiers_members
  ON public.delivery_quartiers
  FOR ALL TO authenticated
  USING      (public._is_shop_member(shop_id))
  WITH CHECK (public._is_shop_member(shop_id));

-- ── Lecture publique (catalogue web) via RPC SECURITY DEFINER ──────────────
-- Renvoie UNIQUEMENT les quartiers de la boutique demandée (filtre shop_id).
-- Aucune donnée sensible (juste ville/quartier/prix de livraison).
CREATE OR REPLACE FUNCTION public.get_public_delivery_quartiers(p_shop_id TEXT)
RETURNS TABLE (
  id      TEXT,
  zone_id TEXT,
  city    TEXT,
  name    TEXT,
  price   INTEGER
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT q.id, q.zone_id, q.city, q.name, q.price
    FROM public.delivery_quartiers q
   WHERE q.shop_id = p_shop_id
   ORDER BY q.city, q.name;
$$;

ALTER FUNCTION public.get_public_delivery_quartiers(TEXT) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_public_delivery_quartiers(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_delivery_quartiers(TEXT)
  TO anon, authenticated;

-- ── Vérification ───────────────────────────────────────────────────────────
--   SELECT tablename, rowsecurity FROM pg_tables
--    WHERE schemaname='public'
--      AND tablename IN ('delivery_zones','delivery_quartiers');
--   SELECT * FROM public.get_public_delivery_quartiers('<shop_id>');
--
-- NB : l'ALTER TABLE orders (delivery_quartier/delivery_price/delivery_zone)
-- viendra avec PR-2 (quand ces champs seront câblés dans Sale + sync).
--
-- Fin — hotfix_127_delivery_zones_quartiers.sql
