-- hotfix_144_activity_station.sql
-- ═════════════════════════════════════════════════════════════════════════
-- POSTE DE SERVICE D'UNE ACTIVITÉ (Lot A du cahier des charges restaurant).
--
-- `restaurant_activities.station` — le poste PHYSIQUE qui prépare les plats
-- d'un secteur : cuisine · bar · chawarma · glacier · pâtisserie.
--
-- POURQUOI cette colonne plutôt qu'un enum `activity_id` figé sur les plats
-- (kitchen/bar/shawarma/ice_cream) comme le demandait la spec d'origine :
--   * `products.activity_id` (hotfix_141) rattache DÉJÀ un plat à un secteur,
--     et les secteurs sont des données de boutique créées par l'utilisateur et
--     synchronisées entre appareils. Un enum Dart aurait figé la liste et
--     n'aurait rien partagé. La spec réclame en réalité deux notions
--     différentes : le SECTEUR (comptable, déjà là) et le POSTE (opérationnel,
--     c'est cette colonne).
--   * Jusqu'ici le poste était DÉDUIT du mode de l'activité (`stock` → bar,
--     `recipe` → cuisine). C'est un proxy qui ne sait pas distinguer une
--     pâtisserie d'une cuisine — limite déjà documentée dans
--     `kitchen_ticket_printer.dart`. Cette colonne la lève.
--
-- NULLABLE À DESSEIN : `NULL` = « poste non précisé » et la déduction par le
-- mode continue de s'appliquer côté Dart (cf. `RoundRouting.stationFor`).
-- Aucune boutique existante n'a besoin d'être migrée, et rien ne casse si la
-- colonne n'est jamais renseignée.
--
-- 100 % idempotent (ré-exécutable sans effet de bord).
-- ═════════════════════════════════════════════════════════════════════════

ALTER TABLE public.restaurant_activities
  ADD COLUMN IF NOT EXISTS station TEXT;

-- CHECK posé séparément : `ADD COLUMN IF NOT EXISTS` ne rejoue pas la
-- contrainte si la colonne préexiste (ré-application du script). Même patron
-- que `orders_order_type_check` dans hotfix_137.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'restaurant_activities_station_check'
       AND conrelid = 'public.restaurant_activities'::regclass
  ) THEN
    ALTER TABLE public.restaurant_activities
      ADD CONSTRAINT restaurant_activities_station_check
      CHECK (station IS NULL OR station IN (
        'cuisine','bar','chawarma','glacier','patisserie','autre'));
  END IF;
END $$;

COMMENT ON COLUMN public.restaurant_activities.station IS
  'Poste de service qui prépare les plats de ce secteur : cuisine · bar · '
  'chawarma · glacier · patisserie · autre. NULL = non précisé, le poste est '
  'alors déduit du `mode` côté application (stock → bar, recipe → cuisine).';

-- ── Vérification ───────────────────────────────────────────────────────────
--   SELECT column_name, data_type, is_nullable
--     FROM information_schema.columns
--    WHERE table_name = 'restaurant_activities' AND column_name = 'station';
--
--   SELECT pg_get_constraintdef(oid) FROM pg_constraint
--    WHERE conname = 'restaurant_activities_station_check';
--
--   -- Répartition des secteurs par poste :
--   SELECT station, count(*) FROM public.restaurant_activities GROUP BY station;
--
-- Fin — hotfix_144_activity_station.sql
