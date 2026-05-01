-- ═══════════════════════════════════════════════════════════════════════════
-- Fortress — Hotfix 005 : whitelist super admin
--
-- Remplace la logique "premier compte = super admin" (vulnérable à la course
-- à l'inscription) par une whitelist d'emails gérée uniquement côté SQL.
--
-- Principe :
--   1. Table super_admin_whitelist (RLS activée, AUCUNE policy → invisible
--      depuis PostgREST, uniquement accessible via SQL Editor avec les
--      credentials Supabase du projet).
--   2. Trigger BEFORE INSERT/UPDATE sur profiles : si l'email correspond
--      à une entrée de la whitelist, force is_super_admin = true.
--   3. Le reset_all_data() préserve la whitelist → les SA reprennent leurs
--      droits automatiquement après un reset + ré-inscription.
--
-- Action :
--   1. Coller ce fichier dans Supabase → SQL Editor → Run.
--   2. ⚠️ MODIFIE le dernier INSERT avec TON email réel avant de Run.
--   3. Désormais, pour ajouter un super admin :
--        INSERT INTO super_admin_whitelist (email, note)
--        VALUES ('cofondateur@domaine.com', 'Co-founder')
--        ON CONFLICT (email) DO NOTHING;
-- ═══════════════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────────────
-- Table whitelist
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS super_admin_whitelist (
  email    TEXT PRIMARY KEY,
  added_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  note     TEXT
);

ALTER TABLE super_admin_whitelist ENABLE ROW LEVEL SECURITY;
-- Aucune policy volontairement → la table est invisible via PostgREST.
-- Tout accès passe par le SQL Editor (authentification propriétaire projet).

-- ───────────────────────────────────────────────────────────────────────────
-- Trigger : élève is_super_admin au moment de l'INSERT profile
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION apply_super_admin_whitelist()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $fn$
BEGIN
  IF NEW.email IS NOT NULL AND EXISTS (
    SELECT 1 FROM super_admin_whitelist
    WHERE lower(email) = lower(NEW.email)
  ) THEN
    NEW.is_super_admin := true;
    -- Log de l'élévation (visible dans l'onglet Logs super admin)
    INSERT INTO activity_logs (actor_id, actor_email, action, target_type, target_id, details)
    VALUES (NEW.id, NEW.email, 'super_admin_granted', 'user',
            NEW.id::text, jsonb_build_object('via', 'whitelist'));
  END IF;
  RETURN NEW;
END $fn$;

DROP TRIGGER IF EXISTS trg_super_admin_whitelist ON profiles;
CREATE TRIGGER trg_super_admin_whitelist
  BEFORE INSERT OR UPDATE OF email ON profiles
  FOR EACH ROW EXECUTE FUNCTION apply_super_admin_whitelist();

-- ───────────────────────────────────────────────────────────────────────────
-- Rétro-application : promeut les comptes déjà existants dont l'email
-- est dans la whitelist (utile si tu remplis la whitelist APRÈS inscription).
-- ───────────────────────────────────────────────────────────────────────────
UPDATE profiles p
   SET is_super_admin = true
  FROM super_admin_whitelist w
 WHERE lower(p.email) = lower(w.email)
   AND COALESCE(p.is_super_admin, false) = false;

-- ───────────────────────────────────────────────────────────────────────────
-- Setup initial — REMPLACE par ton email avant d'exécuter
-- ───────────────────────────────────────────────────────────────────────────
INSERT INTO super_admin_whitelist (email, note)
VALUES ('ton.email@exemple.com', 'Fondateur')
ON CONFLICT (email) DO NOTHING;
