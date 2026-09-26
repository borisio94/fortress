-- hotfix_183_service_state_at.sql
-- ═════════════════════════════════════════════════════════════════════════
-- SERVICE RESTAURANT — l'instant d'entrée dans l'état courant, et les seuils
-- de retard par boutique.
--
-- 1. `orders.service_state_at` — la chronologie du service vit dans quatre
--    drapeaux (sent_to_kitchen, kitchen_ready, served, finished) sans AUCUNE
--    date : impossible de dire depuis combien de temps une commande attend en
--    cuisine ou au passe. UNE colonne, pas quatre : réécrite à chaque
--    transition par le client (`RestaurantOrderService._patchOrder`), c'est
--    exactement ce dont le chronomètre a besoin. NULL sur l'existant — le
--    client n'affiche alors aucun chronomètre, plutôt qu'un faux calculé sur
--    `created_at`.
--
-- 2. `shops.service_late_*_min` — seuils de retard, en minutes, par état.
--    Réglages MÉTIER partagés par tous les appareils : colonnes `shops`, et
--    non `ShopSettingsStore` (Hive local, jamais synchronisé — même raison que
--    `partner_debt_alert_days`, hotfix_178).
--
-- ⚠⚠ CE FICHIER S'APPLIQUE — ET SE VÉRIFIE — AVANT LE DÉPLOIEMENT DU CLIENT.
--
-- `_patchOrder` écrit `service_state_at` DANS LA MÊME MISE À JOUR que les
-- drapeaux. Si la colonne manque, PostgREST refuse la requête ENTIÈRE
-- (PGRST204), drapeaux compris. `orders` étant une table protégée de la file
-- de synchronisation, l'opération serait rejouée sans fin : chaque
-- transition de service d'un restaurant en service serait perdue.
--
-- 100 % idempotent (ré-exécutable sans effet de bord).
-- ═════════════════════════════════════════════════════════════════════════

-- 1. Instant d'entrée dans l'état de service courant ─────────────────────────
alter table public.orders
  add column if not exists service_state_at timestamptz;

comment on column public.orders.service_state_at is
  'Instant d''entrée dans l''état de service courant (drapeaux sent_to_kitchen / kitchen_ready / served / finished). NULL avant le 25/09/2026 : pas de chronomètre.';

-- 2. Seuils de retard du service (minutes) ────────────────────────────────────
alter table public.shops
  add column if not exists service_late_send_min    integer not null default 5,
  add column if not exists service_late_kitchen_min integer not null default 20,
  add column if not exists service_late_pass_min    integer not null default 5;

-- Bornes 1 à 240 min — les mêmes que `AppDatabase.updateShop` côté client.
do $$
begin
  if not exists (select 1 from pg_constraint
                 where conname = 'shops_service_late_send_min_range') then
    alter table public.shops add constraint shops_service_late_send_min_range
      check (service_late_send_min between 1 and 240);
  end if;
  if not exists (select 1 from pg_constraint
                 where conname = 'shops_service_late_kitchen_min_range') then
    alter table public.shops add constraint shops_service_late_kitchen_min_range
      check (service_late_kitchen_min between 1 and 240);
  end if;
  if not exists (select 1 from pg_constraint
                 where conname = 'shops_service_late_pass_min_range') then
    alter table public.shops add constraint shops_service_late_pass_min_range
      check (service_late_pass_min between 1 and 240);
  end if;
end $$;

-- ═════════════════════════════════════════════════════════════════════════
-- VÉRIFICATION — à exécuter APRÈS le fichier, AVANT le build du client.
-- Attendu : 4 lignes (1 colonne orders + 3 colonnes shops).
-- ═════════════════════════════════════════════════════════════════════════
-- select table_name, column_name, data_type, is_nullable, column_default
-- from information_schema.columns
-- where table_schema = 'public'
--   and ((table_name = 'orders' and column_name = 'service_state_at')
--     or (table_name = 'shops'  and column_name like 'service_late_%_min'))
-- order by table_name, column_name;
