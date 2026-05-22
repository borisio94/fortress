-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_090_super_admin_pr3.sql — Super-admin PR-3
--
-- SA-5 : messagerie broadcast. Table `broadcasts` + RPC d'envoi. Pas de
--        table `notifications` serveur (les notifs in-app sont locales) :
--        les clients LISENT les broadcasts qui les ciblent (all / plan /
--        shop) et les affichent. Filtrage côté client + RLS de lecture.
-- SA-7 : incidents critiques globaux. La table `incidents` (hotfix_010) n'a
--        pas de `severity` → on l'ajoute. La policy actuelle limite la
--        lecture aux membres de la boutique → on ajoute une policy de
--        lecture super-admin (toutes boutiques) pour la console.
--
-- Idempotent. RPC SECURITY DEFINER + _is_super_admin().
-- ════════════════════════════════════════════════════════════════════════════

-- ── SA-5 : table broadcasts ─────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.broadcasts (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title        TEXT NOT NULL,
  body         TEXT NOT NULL,
  type         TEXT NOT NULL DEFAULT 'info'
               CHECK (type IN ('info', 'warning', 'maintenance')),
  -- Ciblage : 'all' (toutes les boutiques), 'plan' (target_value = nom du
  -- plan), 'shop' (target_value = shop_id).
  target_type  TEXT NOT NULL DEFAULT 'all'
               CHECK (target_type IN ('all', 'plan', 'shop')),
  target_value TEXT,
  sent_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  sent_by      UUID,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS broadcasts_sent_idx ON public.broadcasts(sent_at DESC);

ALTER TABLE public.broadcasts ENABLE ROW LEVEL SECURITY;

-- Lecture : tous les utilisateurs authentifiés (le filtrage par cible se
-- fait côté client selon la boutique/plan courants).
DROP POLICY IF EXISTS "broadcasts_read" ON public.broadcasts;
CREATE POLICY "broadcasts_read" ON public.broadcasts
  FOR SELECT TO authenticated USING (true);
-- Écriture : via RPC SECURITY DEFINER uniquement (send_broadcast).

-- ── SA-5 : RPC send_broadcast ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.send_broadcast(
  p_title        TEXT,
  p_body         TEXT,
  p_type         TEXT,
  p_target_type  TEXT,
  p_target_value TEXT
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $send_broadcast$
DECLARE
  v_id    UUID;
  v_email TEXT;
BEGIN
  IF NOT public._is_super_admin() THEN
    RAISE EXCEPTION 'forbidden: super-admin requis' USING ERRCODE = '42501';
  END IF;
  IF COALESCE(TRIM(p_title), '') = '' OR COALESCE(TRIM(p_body), '') = '' THEN
    RAISE EXCEPTION 'titre et message requis' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO public.broadcasts
    (title, body, type, target_type, target_value, sent_by)
  VALUES
    (p_title, p_body, COALESCE(p_type, 'info'),
     COALESCE(p_target_type, 'all'), p_target_value, auth.uid())
  RETURNING id INTO v_id;

  SELECT email INTO v_email FROM public.profiles
   WHERE id::text = auth.uid()::text;
  INSERT INTO public.activity_logs
    (actor_id, actor_email, action, target_type, target_id, target_label, details)
  VALUES
    (auth.uid(), v_email, 'broadcast_sent', 'broadcast', v_id::text, p_title,
     jsonb_build_object('type', p_type, 'target', p_target_type));

  RETURN v_id;
END;
$send_broadcast$;

-- ── SA-7 : severity sur incidents ───────────────────────────────────────────
ALTER TABLE public.incidents
  ADD COLUMN IF NOT EXISTS severity TEXT NOT NULL DEFAULT 'normal';
DO $sev_chk$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'incidents_severity_check'
  ) THEN
    ALTER TABLE public.incidents
      ADD CONSTRAINT incidents_severity_check
      CHECK (severity IN ('normal', 'critical'));
  END IF;
END $sev_chk$;

-- SA-7 : lecture super-admin de TOUS les incidents (toutes boutiques).
-- La policy existante `incidents_shop_access` (membres) reste ; on ajoute
-- une policy SELECT dédiée super-admin.
DROP POLICY IF EXISTS "incidents_superadmin_read" ON public.incidents;
CREATE POLICY "incidents_superadmin_read" ON public.incidents
  FOR SELECT TO authenticated
  USING (public._is_super_admin());

-- ── Rechargement du cache de schéma PostgREST ───────────────────────────────
NOTIFY pgrst, 'reload schema';
