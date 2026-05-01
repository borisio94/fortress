-- ═══════════════════════════════════════════════════════════════════════════
-- Fortress — Migration 008 : clients.city + clients.district
-- Sépare l'adresse libre en deux champs exploitables pour l'autocomplétion :
--   * city     — ville (ex: Yaoundé, Douala)
--   * district — quartier (ex: Bastos, Akwa, Bonapriso)
-- `address` est conservé (legacy) mais devient optionnel pour les anciens
-- clients qui ne se sont pas encore vu attribuer city/district.
-- Idempotent grâce à IF NOT EXISTS.
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE clients ADD COLUMN IF NOT EXISTS city     TEXT;
ALTER TABLE clients ADD COLUMN IF NOT EXISTS district TEXT;

-- Index pour autocomplétion rapide par boutique (filtrage côté serveur si besoin)
CREATE INDEX IF NOT EXISTS clients_city_idx
  ON clients(store_id, city)     WHERE city     IS NOT NULL;
CREATE INDEX IF NOT EXISTS clients_district_idx
  ON clients(store_id, district) WHERE district IS NOT NULL;
