-- hotfix_073_expenses_id_text.sql
-- ─────────────────────────────────────────────────────────────────────────
-- Bug : la migration 006 a créé `expenses.id` en UUID
-- (DEFAULT gen_random_uuid()), alors que l'app génère des id TEXTE
-- (`exp_<microsecondes>`) comme pour TOUTES les autres tables
-- (orders.id text, partner_ledger_entries.id text, products.id text…).
-- Conséquence : chaque upsert de dépense est rejeté côté Postgres avec
--   « invalid input syntax for type uuid "exp_..." » (code 22P02)
-- → l'op reste bloquée à vie dans la file offline (table critique,
--   jamais abandonnée) → bannière « Synchro incomplète ».
--
-- Fix : aligner `expenses.id` sur le reste du schéma = TEXT.
-- Les éventuelles lignes existantes (id uuid) sont converties en texte
-- (cast uuid→text valide, aucune perte). Idempotent : ré-exécutable.
-- ─────────────────────────────────────────────────────────────────────────

ALTER TABLE public.expenses ALTER COLUMN id DROP DEFAULT;
ALTER TABLE public.expenses ALTER COLUMN id TYPE text USING id::text;

-- Fin — hotfix_073_expenses_id_text.sql
