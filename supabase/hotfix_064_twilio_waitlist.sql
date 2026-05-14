-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_064_twilio_waitlist.sql
--
-- Liste d'attente publique pour la feature "Automatisation WhatsApp Pro"
-- (intégration Twilio annoncée Q3 2026). La landing page Fortress affiche un
-- encadré "Bientôt" avec capture email — on collecte la demande qualifiée
-- AVANT de coder l'intégration pour valider le pricing premium futur.
--
-- Sécurité :
--   - INSERT anonyme autorisé (visiteur non-loggé sur landing).
--   - SELECT réservé super_admin (consultation depuis l'admin panel).
--   - UPDATE / DELETE : aucun (corrige une fois côté SQL editor si besoin).
--   - Unicité email pour éviter les doublons côté collecte.
-- ════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS twilio_waitlist (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email      TEXT NOT NULL UNIQUE,
  source     TEXT,            -- ex: 'landing_page' / 'pricing_page'
  user_agent TEXT,            -- snapshot navigateur pour stats
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_waitlist_created
  ON twilio_waitlist(created_at DESC);

-- ── RLS ────────────────────────────────────────────────────────────────────
ALTER TABLE twilio_waitlist ENABLE ROW LEVEL SECURITY;

-- Visiteur anonyme peut INSERT (capture depuis la landing publique).
DROP POLICY IF EXISTS waitlist_anon_insert ON twilio_waitlist;
CREATE POLICY waitlist_anon_insert ON twilio_waitlist
  FOR INSERT TO anon
  WITH CHECK (true);

-- Utilisateur authentifié peut aussi INSERT (un futur visiteur loggé qui
-- veut s'inscrire sans logout).
DROP POLICY IF EXISTS waitlist_auth_insert ON twilio_waitlist;
CREATE POLICY waitlist_auth_insert ON twilio_waitlist
  FOR INSERT TO authenticated
  WITH CHECK (true);

-- SELECT réservé super_admin. Pattern aligné sur les autres tables
-- (cf. hotfix_002, hotfix_003, hotfix_005 : check `is_super_admin=true`
-- dans profiles).
DROP POLICY IF EXISTS waitlist_admin_select ON twilio_waitlist;
CREATE POLICY waitlist_admin_select ON twilio_waitlist
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM profiles
       WHERE id = auth.uid()
         AND is_super_admin = true
    )
  );
