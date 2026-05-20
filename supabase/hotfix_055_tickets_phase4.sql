-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_055_tickets_phase4.sql
--
-- Messagerie hiérarchique vendeur ↔ admin ↔ owner ↔ super_admin (v1).
-- Cf. roadmap multi-shop, phase 4 :
--   * Tous les membres peuvent ouvrir un ticket
--   * Mono-shop (un ticket = une boutique)
--   * Texte seul (pas de pièces jointes en v1)
--   * Pas de SLA en v1
--   * Canal `super_admin` réservé aux problèmes plateforme/technique
--
-- Tables :
--   1. shop_tickets               — fil principal
--   2. shop_ticket_messages       — messages échangés
--   3. shop_ticket_escalations    — historique des escalades (admin → owner → super_admin)
--
-- Idempotent.
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1. shop_tickets ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS shop_tickets (
  id            text PRIMARY KEY,
  shop_id       text NOT NULL REFERENCES shops(id) ON DELETE CASCADE,
  opened_by     text NOT NULL,
  current_level text NOT NULL DEFAULT 'admin'
                CHECK (current_level IN ('admin','owner','super_admin')),
  category      text,
  subject       text NOT NULL,
  status        text NOT NULL DEFAULT 'open'
                CHECK (status IN ('open','resolved','closed')),
  priority      text NOT NULL DEFAULT 'normal'
                CHECK (priority IN ('low','normal','high')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  resolved_at   timestamptz
);

CREATE INDEX IF NOT EXISTS shop_tickets_shop_idx     ON shop_tickets(shop_id);
CREATE INDEX IF NOT EXISTS shop_tickets_status_idx   ON shop_tickets(status);
CREATE INDEX IF NOT EXISTS shop_tickets_level_idx    ON shop_tickets(current_level);
CREATE INDEX IF NOT EXISTS shop_tickets_opened_idx   ON shop_tickets(opened_by);
CREATE INDEX IF NOT EXISTS shop_tickets_created_idx  ON shop_tickets(created_at DESC);

-- ── 2. shop_ticket_messages ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS shop_ticket_messages (
  id          text PRIMARY KEY,
  ticket_id   text NOT NULL REFERENCES shop_tickets(id) ON DELETE CASCADE,
  author_id   text NOT NULL,
  body        text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS shop_ticket_messages_ticket_idx
  ON shop_ticket_messages(ticket_id, created_at);

-- ── 3. shop_ticket_escalations ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS shop_ticket_escalations (
  id          text PRIMARY KEY,
  ticket_id   text NOT NULL REFERENCES shop_tickets(id) ON DELETE CASCADE,
  from_level  text NOT NULL CHECK (from_level IN ('admin','owner')),
  to_level    text NOT NULL CHECK (to_level IN ('owner','super_admin')),
  reason      text,
  by_user     text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS shop_ticket_escalations_ticket_idx
  ON shop_ticket_escalations(ticket_id, created_at);

-- ── 4. RLS ────────────────────────────────────────────────────────────────
ALTER TABLE shop_tickets             ENABLE ROW LEVEL SECURITY;
ALTER TABLE shop_ticket_messages     ENABLE ROW LEVEL SECURITY;
ALTER TABLE shop_ticket_escalations  ENABLE ROW LEVEL SECURITY;

-- Tickets — tous les membres de la shop peuvent SELECT (le filtre par
-- hiérarchie est appliqué côté app pour la lisibilité ; ce n'est pas une
-- frontière de sécurité critique car les utilisateurs sont déjà membres
-- légitimes de la shop).
DROP POLICY IF EXISTS shop_tickets_select ON shop_tickets;
CREATE POLICY shop_tickets_select ON shop_tickets
  FOR SELECT TO authenticated
  USING (public._is_shop_member(shop_id));

-- Insert — tout membre peut ouvrir un ticket sur sa shop, en se positionnant
-- comme `opened_by`. Le client envoie current_level='admin' par défaut.
DROP POLICY IF EXISTS shop_tickets_insert ON shop_tickets;
CREATE POLICY shop_tickets_insert ON shop_tickets
  FOR INSERT TO authenticated
  WITH CHECK (
    public._is_shop_member(shop_id)
    AND opened_by = auth.uid()::text
  );

-- Update — résolution et escalade. On laisse au client le contrôle des
-- transitions ; les opérations d'escalade passent par une RPC dédiée
-- (à venir en 4B) qui validera le saut hiérarchique.
DROP POLICY IF EXISTS shop_tickets_update ON shop_tickets;
CREATE POLICY shop_tickets_update ON shop_tickets
  FOR UPDATE TO authenticated
  USING (public._is_shop_member(shop_id))
  WITH CHECK (public._is_shop_member(shop_id));

-- Pas de policy DELETE → tickets immuables (audit trail).

-- Messages — tout membre de la shop du ticket peut lire/écrire.
DROP POLICY IF EXISTS shop_ticket_messages_select ON shop_ticket_messages;
CREATE POLICY shop_ticket_messages_select ON shop_ticket_messages
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM shop_tickets t
       WHERE t.id = ticket_id
         AND public._is_shop_member(t.shop_id)
    )
  );

DROP POLICY IF EXISTS shop_ticket_messages_insert ON shop_ticket_messages;
CREATE POLICY shop_ticket_messages_insert ON shop_ticket_messages
  FOR INSERT TO authenticated
  WITH CHECK (
    author_id = auth.uid()::text
    AND EXISTS (
      SELECT 1 FROM shop_tickets t
       WHERE t.id = ticket_id
         AND public._is_shop_member(t.shop_id)
    )
  );

-- Escalations — lecture pour tous les membres, insertion réservée
-- aux admins/owners de la shop (qui peuvent escalader vers leur supérieur).
DROP POLICY IF EXISTS shop_ticket_escalations_select ON shop_ticket_escalations;
CREATE POLICY shop_ticket_escalations_select ON shop_ticket_escalations
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM shop_tickets t
       WHERE t.id = ticket_id
         AND public._is_shop_member(t.shop_id)
    )
  );

DROP POLICY IF EXISTS shop_ticket_escalations_insert ON shop_ticket_escalations;
CREATE POLICY shop_ticket_escalations_insert ON shop_ticket_escalations
  FOR INSERT TO authenticated
  WITH CHECK (
    by_user = auth.uid()::text
    AND EXISTS (
      SELECT 1 FROM shop_tickets t
       WHERE t.id = ticket_id
         AND public._is_shop_admin(t.shop_id)
    )
  );

-- ── 5. Trigger updated_at sur shop_tickets ───────────────────────────────
CREATE OR REPLACE FUNCTION public._shop_tickets_set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS shop_tickets_updated_at ON shop_tickets;
CREATE TRIGGER shop_tickets_updated_at
  BEFORE UPDATE ON shop_tickets
  FOR EACH ROW EXECUTE FUNCTION public._shop_tickets_set_updated_at();

-- ── 6. Realtime ──────────────────────────────────────────────────────────
-- Active la publication realtime pour les 3 tables. Idempotent.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
     WHERE pubname='supabase_realtime' AND tablename='shop_tickets'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE shop_tickets;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
     WHERE pubname='supabase_realtime' AND tablename='shop_ticket_messages'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE shop_ticket_messages;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
     WHERE pubname='supabase_realtime' AND tablename='shop_ticket_escalations'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE shop_ticket_escalations;
  END IF;
END
$$;

-- ════════════════════════════════════════════════════════════════════════════
-- Vérifications post-exécution :
--
--   SELECT table_name FROM information_schema.tables
--    WHERE table_name LIKE 'shop_ticket%';
--   -- Doit renvoyer les 3 tables.
--
--   SELECT count(*) FROM shop_tickets;        -- 0 attendu (table neuve)
-- ════════════════════════════════════════════════════════════════════════════
