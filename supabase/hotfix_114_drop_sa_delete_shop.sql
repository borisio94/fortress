-- =============================================================================
-- hotfix_114_drop_sa_delete_shop.sql
--
-- Revert de la suppression MANUELLE de boutique (annule la RPC du hotfix_113).
-- Décision produit : on ne supprime plus une boutique « à la main » depuis le
-- super-admin. Une boutique disparaît AUTOMATIQUEMENT quand son propriétaire est
-- supprimé (RPC `delete_user_account` → `_purge_shop_dependents` +
-- `DELETE FROM shops WHERE owner_id` → cascade memberships).
--
-- ⚠️ On NE TOUCHE PAS à `_purge_shop_dependents` (qui ne supprime plus les
-- memberships) ni à la FK `shop_memberships.shop_id → shops.id ON DELETE
-- CASCADE` : ces deux correctifs (cf. migrations/013) restent nécessaires pour
-- que la suppression du propriétaire fasse bien disparaître la boutique sans
-- être bloquée par le trigger `trg_protect_owner_delete` (hotfix_025).
--
-- Idempotente.
-- =============================================================================

DROP FUNCTION IF EXISTS public.sa_delete_shop(uuid);

-- Recharger le cache de schéma PostgREST
NOTIFY pgrst, 'reload schema';
