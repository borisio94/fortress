-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_107_sa_user_status.sql  —  Blocage/déblocage de compte par le SA
--
-- Bug : la section Utilisateurs (super-admin) faisait un
-- `UPDATE profiles SET prof_status=…` EN DIRECT, mais la policy RLS
-- `profiles_update` (hotfix_041) n'autorise QUE `id = auth.uid()` → un SA ne
-- pouvait pas modifier le profil d'un AUTRE utilisateur. L'update était
-- silencieusement rejeté (0 ligne) → le blocage n'avait aucun effet.
--
-- Correctif : RPC SECURITY DEFINER `sa_set_user_status`, réservée super-admin,
-- qui met à jour UNIQUEMENT prof_status + blocked_at. L'app l'appelle au lieu
-- de l'update direct. Combiné à hotfix_106 (get_user_plan reflète
-- prof_status='blocked'), le compte est réellement verrouillé.
--
-- Idempotent.
-- ════════════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS public.sa_set_user_status(text, text);
CREATE FUNCTION public.sa_set_user_status(p_user_id text, p_status text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
BEGIN
  IF NOT public._is_super_admin() THEN
    RAISE EXCEPTION 'forbidden: super-admin requis' USING ERRCODE = '42501';
  END IF;
  IF p_status NOT IN ('active', 'blocked') THEN
    RAISE EXCEPTION 'statut invalide (active | blocked)' USING ERRCODE = 'P0001';
  END IF;

  UPDATE profiles
     SET prof_status = p_status,
         blocked_at  = CASE WHEN p_status = 'blocked' THEN now() ELSE NULL END
   WHERE id::text = p_user_id
     AND COALESCE(is_super_admin, false) = false;  -- jamais bloquer un SA

  IF NOT FOUND THEN
    RAISE EXCEPTION 'utilisateur introuvable (ou super-admin)' USING ERRCODE = 'P0002';
  END IF;

  RETURN jsonb_build_object('user_id', p_user_id, 'prof_status', p_status);
END $fn$;

REVOKE ALL ON FUNCTION public.sa_set_user_status(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.sa_set_user_status(text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
