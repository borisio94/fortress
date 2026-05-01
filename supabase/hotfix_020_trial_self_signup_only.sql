-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_020_trial_self_signup_only.sql
--
-- Le trigger trg_trial_on_profile_insert créait une subscription "trial" pour
-- TOUS les profils insérés — y compris pour les employés créés via
-- create_employee() (hotfix_018), ce qui n'a aucun sens : un employé n'est
-- pas censé avoir son propre plan, il hérite de celui du propriétaire de
-- la boutique.
--
-- Fix : ne déclencher le trial que sur self-signup, c.-à-d. quand
-- auth.uid() = NEW.id (l'utilisateur insère son propre profil après
-- s'être inscrit lui-même via Supabase Auth). Pour un employé créé par
-- un admin, auth.uid() = admin → skip.
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.create_trial_subscription()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $create_trial$
DECLARE
  v_plan_id     UUID;
  v_trial_days  INT;
  v_caller_uid  UUID;
BEGIN
  v_caller_uid := auth.uid();

  -- Skip pour les profils créés par un autre utilisateur (typiquement
  -- create_employee : un admin/owner crée le profil de l'employé).
  -- Un trial n'est accordé que lors d'un self-signup où auth.uid() = NEW.id.
  IF v_caller_uid IS NOT NULL AND v_caller_uid::text <> NEW.id::text THEN
    RETURN NEW;
  END IF;

  -- Skip si l'utilisateur est déjà membre d'une boutique (cas rare où
  -- un employé re-créerait son profil après suppression).
  IF EXISTS (
    SELECT 1 FROM shop_memberships
     WHERE user_id::text = NEW.id::text
       AND COALESCE(status, 'active') = 'active'
  ) THEN
    RETURN NEW;
  END IF;

  SELECT id, trial_days
    INTO v_plan_id, v_trial_days
    FROM plans
   WHERE name = 'trial' AND trial_days > 0
   LIMIT 1;

  IF v_plan_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF EXISTS (
    SELECT 1 FROM subscriptions
     WHERE user_id = NEW.id
       AND sub_status IN ('active','trial')
  ) THEN
    RETURN NEW;
  END IF;

  INSERT INTO subscriptions
      (user_id, plan_id, billing_cycle, sub_status,
       started_at, expires_at, amount_paid)
  VALUES
      (NEW.id, v_plan_id, 'monthly', 'trial',
       now(), now() + (v_trial_days || ' days')::INTERVAL, 0);

  RETURN NEW;
END;
$create_trial$;

-- Le trigger lui-même reste inchangé (DROP/CREATE par sécurité)
DROP TRIGGER IF EXISTS trg_trial_on_profile_insert ON profiles;
CREATE TRIGGER trg_trial_on_profile_insert
AFTER INSERT ON profiles
FOR EACH ROW EXECUTE FUNCTION public.create_trial_subscription();

-- ════════════════════════════════════════════════════════════════════════════
-- Cleanup : supprimer les subscriptions trial parasites créées pour les
-- employés existants. Un employé est identifié par : il a une membership
-- active dans une boutique qu'il ne possède pas.
-- ════════════════════════════════════════════════════════════════════════════
DELETE FROM subscriptions s
 WHERE s.sub_status = 'trial'
   AND EXISTS (
     SELECT 1 FROM shop_memberships sm
      WHERE sm.user_id::text = s.user_id::text
        AND COALESCE(sm.status, 'active') = 'active'
   )
   AND NOT EXISTS (
     SELECT 1 FROM shops sh
      WHERE sh.owner_id::text = s.user_id::text
   );

-- ════════════════════════════════════════════════════════════════════════════
-- Fix get_user_plan : pour un employé sans subscription propre, retourner
-- le plan du propriétaire de l'une de ses boutiques actives. Évite que
-- l'employé soit redirigé vers le paywall /subscription.
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
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $get_plan$
DECLARE
  v_owner_id  UUID;
  v_uid_t     TEXT := p_user_id::text;
BEGIN
  -- ⚠ Toutes les références à la colonne `sub_status` doivent être
  --   qualifiées (alias de table) car la RETURN TABLE contient aussi
  --   une colonne `sub_status` → erreur 42702 sinon.

  -- 1. Si l'utilisateur a une subscription propre, on l'utilise.
  IF EXISTS (
    SELECT 1 FROM subscriptions sub
     WHERE sub.user_id::text = v_uid_t
       AND sub.sub_status IN ('active','trial')
  ) THEN
    RETURN QUERY
    SELECT
      COALESCE(pl.name, 'none')             AS plan_name,
      COALESCE(pl.offline_enabled, false)   AS offline_enabled,
      COALESCE(pl.max_shops, 0)             AS max_shops,
      COALESCE(pl.max_users_per_shop, 0)    AS max_users_per_shop,
      COALESCE(pl.max_products, 0)          AS max_products,
      COALESCE(pl.features, '[]'::jsonb)    AS features,
      COALESCE(s.sub_status, 'none')        AS sub_status,
      s.expires_at                           AS expires_at,
      (COALESCE(pr.prof_status, 'active') = 'blocked') AS is_blocked
    FROM profiles pr
    LEFT JOIN LATERAL (
      SELECT * FROM subscriptions sub2
       WHERE sub2.user_id::text = v_uid_t
         AND sub2.sub_status IN ('active','trial')
       ORDER BY sub2.expires_at DESC
       LIMIT 1
    ) s ON true
    LEFT JOIN plans pl ON pl.id = s.plan_id
    WHERE pr.id::text = v_uid_t;
    RETURN;
  END IF;

  -- 2. Sinon : utilisateur sans plan propre → chercher le plan du
  --    propriétaire d'une boutique active dont il est membre.
  SELECT sh.owner_id INTO v_owner_id
    FROM shop_memberships sm
    JOIN shops sh ON sh.id::text = sm.shop_id::text
   WHERE sm.user_id::text = v_uid_t
     AND COALESCE(sm.status, 'active') = 'active'
   ORDER BY sm.created_at NULLS LAST
   LIMIT 1;

  IF v_owner_id IS NOT NULL THEN
    RETURN QUERY
    SELECT
      COALESCE(pl.name, 'none')             AS plan_name,
      COALESCE(pl.offline_enabled, false)   AS offline_enabled,
      COALESCE(pl.max_shops, 0)             AS max_shops,
      COALESCE(pl.max_users_per_shop, 0)    AS max_users_per_shop,
      COALESCE(pl.max_products, 0)          AS max_products,
      COALESCE(pl.features, '[]'::jsonb)    AS features,
      COALESCE(s.sub_status, 'none')        AS sub_status,
      s.expires_at                           AS expires_at,
      (COALESCE(pr.prof_status, 'active') = 'blocked') AS is_blocked
    FROM profiles pr
    LEFT JOIN LATERAL (
      SELECT * FROM subscriptions sub3
       WHERE sub3.user_id::text = v_owner_id::text
         AND sub3.sub_status IN ('active','trial')
       ORDER BY sub3.expires_at DESC
       LIMIT 1
    ) s ON true
    LEFT JOIN plans pl ON pl.id = s.plan_id
    WHERE pr.id::text = v_uid_t;  -- profil de l'employé, plan de l'owner
    RETURN;
  END IF;

  -- 3. Sinon : pas de plan, pas de boutique → retour standard "none"
  RETURN QUERY
  SELECT
    'none'::TEXT, false, 0, 0, 0, '[]'::jsonb,
    'none'::TEXT, NULL::TIMESTAMPTZ,
    (COALESCE(pr.prof_status, 'active') = 'blocked')
  FROM profiles pr
  WHERE pr.id::text = v_uid_t;
END;
$get_plan$;

GRANT EXECUTE ON FUNCTION public.get_user_plan(UUID) TO authenticated;
