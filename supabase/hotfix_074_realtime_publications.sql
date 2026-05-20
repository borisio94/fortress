-- hotfix_074_realtime_publications.sql
-- ─────────────────────────────────────────────────────────────────────────
-- Même classe de bug que partner_ledger (hotfix_072) : 12 tables sont
-- écoutées côté app via `.onPostgresChanges(... table: 'X' ...)` mais
-- AUCUN `ALTER PUBLICATION supabase_realtime ADD TABLE` n'existait dans le
-- SQL versionné. Si une de ces tables n'est pas membre de la publication
-- `supabase_realtime`, ses changements ne sont JAMAIS diffusés en temps
-- réel → propagation inter-appareils seulement au pull complet (lenteur
-- 15 s à plusieurs minutes). Certaines ont pu être ajoutées à la main via
-- le dashboard (état NON tracé dans le repo → régression silencieuse au
-- moindre reset / nouvel environnement).
--
-- Ce hotfix rend la configuration Realtime EXPLICITE et reproductible.
-- Idempotent : chaque ADD TABLE n'est exécuté que si la table n'est pas
-- déjà publiée. Sûr à ré-exécuter.
-- ─────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
  t text;
  tables text[] := ARRAY[
    'products', 'categories', 'brands', 'units', 'clients', 'orders',
    'suppliers', 'incidents', 'stock_movements', 'receptions',
    'purchase_orders', 'stock_arrivals'
  ];
BEGIN
  FOREACH t IN ARRAY tables LOOP
    IF EXISTS (
      SELECT 1 FROM information_schema.tables
      WHERE table_schema = 'public' AND table_name = t
    ) AND NOT EXISTS (
      SELECT 1 FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime'
        AND schemaname = 'public'
        AND tablename = t
    ) THEN
      EXECUTE format(
        'ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', t);
      RAISE NOTICE 'Realtime: ajouté %', t;
    END IF;
  END LOOP;
END $$;

-- Diagnostic : lister ce qui est désormais publié.
-- SELECT tablename FROM pg_publication_tables
--  WHERE pubname='supabase_realtime' AND schemaname='public' ORDER BY 1;

-- Fin — hotfix_074_realtime_publications.sql
