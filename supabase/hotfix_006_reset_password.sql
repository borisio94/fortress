-- ═══════════════════════════════════════════════════════════════════════════
-- Fortress — Hotfix 006 : détection super admin pour le reset de mot de passe
--
-- Permet au client NON authentifié de savoir si un email correspond à un
-- super admin, afin de déclencher le flux OTP renforcé au lieu du magic-link
-- standard. Ne révèle RIEN d'autre : uniquement un booléen.
--
-- Action :
--   1. Coller ce fichier dans Supabase → SQL Editor → Run.
--   2. Vérifier que l'appel anon fonctionne :
--        SELECT is_super_admin_email('ton.email@domaine.com');
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION is_super_admin_email(p_email TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $fn$
DECLARE
  v_result BOOLEAN;
BEGIN
  IF p_email IS NULL OR length(trim(p_email)) = 0 THEN
    RETURN false;
  END IF;

  -- Une ligne dans la whitelist OU is_super_admin=true dans profiles suffit.
  SELECT EXISTS (
    SELECT 1 FROM super_admin_whitelist
    WHERE lower(email) = lower(trim(p_email))
  ) OR EXISTS (
    SELECT 1 FROM profiles
    WHERE lower(email) = lower(trim(p_email))
      AND COALESCE(is_super_admin, false) = true
  )
  INTO v_result;

  RETURN COALESCE(v_result, false);
END $fn$;

-- Exposer la fonction aux rôles anonymes et authentifiés
GRANT EXECUTE ON FUNCTION is_super_admin_email(TEXT) TO anon, authenticated;
