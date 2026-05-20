-- hotfix_044_active_sessions.sql
-- Gestion des sessions simultanées par utilisateur, avec limite par rôle.
--   • super_admin → 5 sessions
--   • owner (au moins 1 boutique en owner) → 3 sessions
--   • admin (au moins 1 boutique en admin) → 2 sessions
--   • user uniquement → 1 session active
--
-- Le client (Flutter) :
--   1. Génère un device_id stable (UUID v4 persisté Hive).
--   2. Appelle `register_session` au login → upsert + cleanup excès.
--   3. Heartbeat `heartbeat_session` toutes les 5 min → met à jour last_seen.
--   4. Écoute Realtime sur `active_sessions` filtré (user_id, device_id) :
--      si la row courante DISPARAÎT → l'utilisateur est forcé à se déconnecter
--      (snack "Vous avez été déconnecté car une nouvelle session a été ouverte").
--
-- Idempotent : sûr à ré-exécuter (DROP IF EXISTS / CREATE OR REPLACE partout).

-- ─── Table ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.active_sessions (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  device_id   text NOT NULL,
  platform    text,                                  -- 'web' | 'android' | 'ios' | 'windows' | 'macos' | 'linux'
  user_agent  text,
  last_seen   timestamptz NOT NULL DEFAULT now(),
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT active_sessions_user_device_unique UNIQUE (user_id, device_id)
);

CREATE INDEX IF NOT EXISTS active_sessions_user_id_idx
  ON public.active_sessions (user_id);
CREATE INDEX IF NOT EXISTS active_sessions_last_seen_idx
  ON public.active_sessions (last_seen);

-- Realtime publication (pour le soft-kick côté client).
ALTER PUBLICATION supabase_realtime ADD TABLE public.active_sessions;

-- ─── RLS ────────────────────────────────────────────────────────────────────
ALTER TABLE public.active_sessions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "active_sessions_self_select" ON public.active_sessions;
CREATE POLICY "active_sessions_self_select"
  ON public.active_sessions FOR SELECT
  USING (user_id = auth.uid());

-- Insert/Update/Delete passent UNIQUEMENT par les RPCs (SECURITY DEFINER).
-- Pas de policy d'écriture directe — verrouillage au niveau RLS.

-- ─── Helper : limite de sessions selon rôle global ──────────────────────────
CREATE OR REPLACE FUNCTION public._session_limit(p_user_id uuid)
RETURNS int
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_super bool;
BEGIN
  IF p_user_id IS NULL THEN RETURN 0; END IF;

  SELECT COALESCE(is_super_admin, false) INTO v_super
    FROM profiles WHERE id = p_user_id;
  IF v_super THEN RETURN 5; END IF;

  IF EXISTS (SELECT 1 FROM shop_memberships
             WHERE user_id = p_user_id::text AND role = 'owner') THEN
    RETURN 3;
  END IF;

  IF EXISTS (SELECT 1 FROM shop_memberships
             WHERE user_id = p_user_id::text AND role = 'admin') THEN
    RETURN 2;
  END IF;

  RETURN 1;
END;
$$;

REVOKE ALL ON FUNCTION public._session_limit(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public._session_limit(uuid) TO authenticated;

-- ─── RPC : register_session ─────────────────────────────────────────────────
-- Upsert (user_id, device_id) + cleanup des sessions excédentaires.
-- Retourne le nombre de sessions actives APRÈS cleanup.
CREATE OR REPLACE FUNCTION public.register_session(
  p_device_id  text,
  p_platform   text DEFAULT NULL,
  p_user_agent text DEFAULT NULL
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_limit int;
  v_count int;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '42501';
  END IF;
  IF p_device_id IS NULL OR length(trim(p_device_id)) = 0 THEN
    RAISE EXCEPTION 'device_id_required' USING ERRCODE = '22023';
  END IF;

  -- 1) Upsert la session courante.
  INSERT INTO active_sessions (user_id, device_id, platform, user_agent, last_seen)
  VALUES (v_uid, p_device_id, p_platform, p_user_agent, now())
  ON CONFLICT (user_id, device_id) DO UPDATE
    SET platform   = COALESCE(EXCLUDED.platform, active_sessions.platform),
        user_agent = COALESCE(EXCLUDED.user_agent, active_sessions.user_agent),
        last_seen  = now();

  -- 2) Cleanup des sessions inactives > 30 minutes (toutes confondues).
  DELETE FROM active_sessions
   WHERE user_id = v_uid
     AND last_seen < now() - interval '30 minutes'
     AND device_id <> p_device_id;

  -- 3) Si on dépasse la limite, supprimer les plus anciennes (last_seen ASC),
  --    en gardant TOUJOURS la session courante (p_device_id).
  v_limit := _session_limit(v_uid);
  SELECT count(*) INTO v_count FROM active_sessions WHERE user_id = v_uid;

  IF v_count > v_limit THEN
    DELETE FROM active_sessions
     WHERE id IN (
       SELECT id FROM active_sessions
        WHERE user_id = v_uid AND device_id <> p_device_id
        ORDER BY last_seen ASC
        LIMIT (v_count - v_limit)
     );
  END IF;

  SELECT count(*) INTO v_count FROM active_sessions WHERE user_id = v_uid;
  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.register_session(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.register_session(text, text, text) TO authenticated;

-- ─── RPC : heartbeat_session ────────────────────────────────────────────────
-- Met à jour last_seen pour la session courante.
-- Retourne true si la session existe encore (sinon false → kick reçu).
CREATE OR REPLACE FUNCTION public.heartbeat_session(p_device_id text)
RETURNS bool
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_rows int;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '42501';
  END IF;

  UPDATE active_sessions
     SET last_seen = now()
   WHERE user_id = v_uid AND device_id = p_device_id;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows > 0;
END;
$$;

REVOKE ALL ON FUNCTION public.heartbeat_session(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.heartbeat_session(text) TO authenticated;

-- ─── RPC : revoke_other_sessions ────────────────────────────────────────────
-- Supprime toutes les sessions de l'utilisateur SAUF p_keep_device_id.
-- Retourne le nombre de sessions supprimées.
CREATE OR REPLACE FUNCTION public.revoke_other_sessions(p_keep_device_id text)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid  uuid := auth.uid();
  v_rows int;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '42501';
  END IF;

  DELETE FROM active_sessions
   WHERE user_id = v_uid AND device_id <> p_keep_device_id;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows;
END;
$$;

REVOKE ALL ON FUNCTION public.revoke_other_sessions(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.revoke_other_sessions(text) TO authenticated;

-- ─── RPC : revoke_session ───────────────────────────────────────────────────
-- Supprime une session précise (logout côté client).
CREATE OR REPLACE FUNCTION public.revoke_session(p_device_id text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '42501';
  END IF;

  DELETE FROM active_sessions
   WHERE user_id = v_uid AND device_id = p_device_id;
END;
$$;

REVOKE ALL ON FUNCTION public.revoke_session(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.revoke_session(text) TO authenticated;

-- ─── RPC : list_my_sessions ─────────────────────────────────────────────────
-- Retourne les sessions actives de l'utilisateur courant.
CREATE OR REPLACE FUNCTION public.list_my_sessions()
RETURNS TABLE (
  id          uuid,
  device_id   text,
  platform    text,
  user_agent  text,
  last_seen   timestamptz,
  created_at  timestamptz
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, auth
AS $$
  SELECT id, device_id, platform, user_agent, last_seen, created_at
    FROM active_sessions
   WHERE user_id = auth.uid()
   ORDER BY last_seen DESC;
$$;

REVOKE ALL ON FUNCTION public.list_my_sessions() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_my_sessions() TO authenticated;
