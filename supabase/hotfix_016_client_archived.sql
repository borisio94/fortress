-- ═══════════════════════════════════════════════════════════════════════════
-- Fortress — Hotfix 016 : Soft-delete (archivage) des clients
--
-- Ajoute la colonne `is_archived` à la table clients (nullable, default false).
-- Les clients archivés sont masqués des listes / sélecteurs mais l'historique
-- des commandes qui les référence reste intact.
--
-- Action : coller dans Supabase → SQL Editor → Run. Idempotent.
-- ═══════════════════════════════════════════════════════════════════════════

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'clients' AND column_name = 'is_archived'
  ) THEN
    ALTER TABLE clients ADD COLUMN is_archived BOOLEAN NOT NULL DEFAULT false;
  END IF;
END $$;

-- Index partiel pour accélérer les requêtes "clients actifs" (99 % des cas)
CREATE INDEX IF NOT EXISTS clients_active_idx
  ON clients(store_id)
  WHERE is_archived = false;

-- ═══════════════════════════════════════════════════════════════════════════
-- Fin — hotfix_016_client_archived.sql
-- ═══════════════════════════════════════════════════════════════════════════
