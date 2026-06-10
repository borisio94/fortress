-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_106_blocked_account.sql  —  Rendre le blocage de compte EFFECTIF
--
-- Bug d'origine : l'action super-admin « Bloquer » écrit
-- `profiles.prof_status='blocked'`, mais `get_user_plan` ne dérivait pas
-- `is_blocked` de `prof_status` → le blocage n'avait aucun effet.
--
-- ⚠️ Deux pièges de la définition à respecter :
--   1. La table `profiles` n'a PAS de colonne `is_blocked` → ne JAMAIS la
--      référencer (sinon erreur 42703 à l'exécution). Le blocage = prof_status.
--   2. Les colonnes de sortie (RETURNS TABLE) `sub_status` / `expires_at`
--      portent le même nom que des colonnes de `subscriptions` → DANS la
--      sous-requête LATERAL il FAUT qualifier (sub.sub_status, sub.expires_at)
--      sinon erreur 42702 « column reference ambiguous » → get_user_plan
--      plante → l'app affiche TOUS les comptes « Expiré ».
--
-- Correctif : `is_blocked = (prof_status = 'blocked')` + colonnes LATERAL
-- qualifiées. Idempotent.
-- ════════════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS public.get_user_plan(UUID);
CREATE OR REPLACE FUNCTION public.get_user_plan(p_user_id UUID)
RETURNS TABLE (
  plan_name           TEXT,
  offline_enabled     BOOLEAN,
  max_shops           INT,
  max_users_per_shop  INT,
  max_products        INT,
  features            JSONB,
  sub_status          TEXT,
  expires_at          TIMESTAMPTZ,
  is_blocked          BOOLEAN
) LANGUAGE plpgsql STABLE SECURITY DEFINER AS $get_plan$
BEGIN
  RETURN QUERY
  SELECT
    COALESCE(p.name, 'none'),
    COALESCE(p.offline_enabled, false),
    COALESCE(p.max_shops, 0),
    COALESCE(p.max_users_per_shop, 0),
    COALESCE(p.max_products, 0),
    COALESCE(p.features, '[]'::jsonb),
    COALESCE(s.sub_status, 'none'),
    s.expires_at,
    (pr.prof_status = 'blocked')
  FROM profiles pr
  LEFT JOIN LATERAL (
    SELECT sub.sub_status, sub.expires_at, sub.plan_id
      FROM subscriptions sub
     WHERE sub.user_id = p_user_id
       AND sub.sub_status IN ('active','trial')
     ORDER BY sub.expires_at DESC
     LIMIT 1
  ) s ON true
  LEFT JOIN plans p ON p.id = s.plan_id
  WHERE pr.id = p_user_id;
END;
$get_plan$;

GRANT EXECUTE ON FUNCTION public.get_user_plan(UUID) TO authenticated;
