-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_110_plans_v3.sql  —  Refonte tarifaire (Essai / Starter / Pro / Business)
--
-- Modèle (tout reste éditable par le SA via upsert_plan) :
--   Essai (14j)  : quotas = BUSINESS (accès max), toutes fonctionnalités,
--                  attribué auto à chaque nouveau compte (is_active=false,
--                  gardé pour le trigger de trial auto + masqué du /pricing).
--   Starter 3500 : 1 boutique · 0 employé · 1 partenaire · 0 magasin · 500 prod.
--   Pro     6000 : 3 boutiques · 2 employés/boutique · 3 partenaires ·
--                  3 magasins · 1500 produits.
--   Business     : 5 boutiques · 3 employés/boutique (15) · 10 partenaires ·
--                  10 magasins · produits illimités.
--   Pro Plus     : SUPPRIMÉ.
--   Trimestriel −10 % · Annuel −20 %.
--   Partenaires & magasins = TOTAUX par compte ; employés = par boutique.
--
-- Idempotent.
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. Colonne magasins ─────────────────────────────────────────────────────
ALTER TABLE plans
  ADD COLUMN IF NOT EXISTS max_warehouses INT DEFAULT 0;

-- ── 2. Supprimer Pro Plus (créé par une version précédente) ──────────────────
DELETE FROM plans WHERE name = 'pro_plus';

-- ── 3. Données des plans ─────────────────────────────────────────────────────
-- Starter
UPDATE plans SET
  price_monthly               = 3500,
  price_quarterly             = 9450,    -- 3500×3×0.9
  price_yearly                = 33600,   -- 3500×12×0.8
  max_shops                   = 1,
  max_users_per_shop          = 1,       -- owner seul (0 employé)
  max_employees_per_shop      = 0,
  max_partner_depots_per_shop = 1,
  max_warehouses              = 0,
  max_products                = 500,
  is_active                   = true,
  sort_order                  = 1
WHERE name = 'starter';

-- Pro
UPDATE plans SET
  price_monthly               = 6000,
  price_quarterly             = 16200,   -- 6000×3×0.9
  price_yearly                = 57600,   -- 6000×12×0.8
  max_shops                   = 3,
  max_users_per_shop          = 3,       -- owner + 2 employés
  max_employees_per_shop      = 2,
  max_partner_depots_per_shop = 3,
  max_warehouses              = 3,
  max_products                = 1500,
  is_active                   = true,
  sort_order                  = 2
WHERE name = 'pro';

-- Business (réactivé)
UPDATE plans SET
  price_monthly               = 18000,
  price_quarterly             = 48600,   -- 18000×3×0.9
  price_yearly                = 172800,  -- 18000×12×0.8
  max_shops                   = 5,
  max_users_per_shop          = 4,       -- owner + 3 employés
  max_employees_per_shop      = 3,       -- 3/boutique × 5 = 15
  max_partner_depots_per_shop = 10,
  max_warehouses              = 10,
  max_products                = 2147483647,
  is_active                   = true,
  sort_order                  = 3
WHERE name = 'business';

-- Essai = quotas BUSINESS (accès maximum) + toutes fonctionnalités, 14 jours,
-- attribué auto à chaque nouveau compte (trigger create_trial_subscription).
-- is_active=false conservé (masqué du /pricing, lu par le trigger via trial_days>0).
UPDATE plans SET
  max_shops                   = 5,
  max_users_per_shop          = 4,
  max_employees_per_shop      = 3,
  max_partner_depots_per_shop = 10,
  max_warehouses              = 10,
  max_products                = 2147483647,
  offline_enabled             = true,
  trial_days                  = 14,
  is_active                   = false
WHERE name = 'trial';

-- Fonctionnalités : Starter/Business/Essai héritent du jeu de Pro (= toutes).
UPDATE plans SET features = (SELECT features FROM plans WHERE name = 'pro')
 WHERE name IN ('trial', 'starter', 'business');

COMMIT;

-- ── 4. get_user_plan : renvoie les nouveaux quotas ──────────────────────────
-- ⚠️ (cf. hotfix_106) pas de colonne is_blocked (→ prof_status) ; qualifier
-- sub.* dans la LATERAL (sinon 42702 ambiguous).
DROP FUNCTION IF EXISTS public.get_user_plan(UUID);
CREATE OR REPLACE FUNCTION public.get_user_plan(p_user_id UUID)
RETURNS TABLE (
  plan_name           TEXT,
  offline_enabled     BOOLEAN,
  max_shops           INT,
  max_users_per_shop  INT,
  max_products        INT,
  max_partner_depots  INT,
  max_employees_per_shop INT,
  max_warehouses      INT,
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
    COALESCE(p.max_partner_depots_per_shop, 0),
    COALESCE(p.max_employees_per_shop, 0),
    COALESCE(p.max_warehouses, 0),
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

-- ── 5. upsert_plan : édite TOUS les champs (partenaires/employés/magasins) ──
DROP FUNCTION IF EXISTS public.upsert_plan(UUID, TEXT, TEXT, NUMERIC, NUMERIC, NUMERIC, INT, INT, INT, JSONB, BOOLEAN, INT, BOOLEAN);
DROP FUNCTION IF EXISTS public.upsert_plan(UUID, TEXT, TEXT, NUMERIC, NUMERIC, NUMERIC, INT, INT, INT, JSONB, BOOLEAN, INT, BOOLEAN, INT, INT, INT);
CREATE OR REPLACE FUNCTION public.upsert_plan(
  p_id                 UUID,
  p_name               TEXT,
  p_label              TEXT,
  p_price_monthly      NUMERIC,
  p_price_quarterly    NUMERIC,
  p_price_yearly       NUMERIC,
  p_max_products       INT,
  p_max_users_per_shop INT,
  p_max_shops          INT,
  p_features           JSONB,
  p_offline_enabled    BOOLEAN,
  p_trial_days         INT,
  p_is_active          BOOLEAN,
  p_max_partner_depots INT DEFAULT NULL,
  p_max_employees_per_shop INT DEFAULT NULL,
  p_max_warehouses     INT DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $upsert_plan$
DECLARE
  v_id    UUID;
  v_email TEXT;
BEGIN
  IF NOT public._is_super_admin() THEN
    RAISE EXCEPTION 'forbidden: super-admin requis' USING ERRCODE = '42501';
  END IF;
  IF COALESCE(TRIM(p_name), '') = '' THEN
    RAISE EXCEPTION 'nom du plan requis' USING ERRCODE = 'P0001';
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO public.plans
      (name, label, price_monthly, price_quarterly, price_yearly,
       max_products, max_users_per_shop, max_shops, features,
       offline_enabled, trial_days, is_active,
       max_partner_depots_per_shop, max_employees_per_shop, max_warehouses)
    VALUES
      (p_name, p_label, COALESCE(p_price_monthly, 0),
       COALESCE(p_price_quarterly, 0), COALESCE(p_price_yearly, 0),
       COALESCE(p_max_products, 50), COALESCE(p_max_users_per_shop, 1),
       COALESCE(p_max_shops, 1), COALESCE(p_features, '[]'::jsonb),
       COALESCE(p_offline_enabled, false), COALESCE(p_trial_days, 0),
       COALESCE(p_is_active, true),
       COALESCE(p_max_partner_depots, 0), COALESCE(p_max_employees_per_shop, 0),
       COALESCE(p_max_warehouses, 0))
    RETURNING id INTO v_id;
  ELSE
    UPDATE public.plans
       SET name               = p_name,
           label              = p_label,
           price_monthly      = COALESCE(p_price_monthly, price_monthly),
           price_quarterly    = COALESCE(p_price_quarterly, price_quarterly),
           price_yearly       = COALESCE(p_price_yearly, price_yearly),
           max_products       = COALESCE(p_max_products, max_products),
           max_users_per_shop = COALESCE(p_max_users_per_shop, max_users_per_shop),
           max_shops          = COALESCE(p_max_shops, max_shops),
           features           = COALESCE(p_features, features),
           offline_enabled    = COALESCE(p_offline_enabled, offline_enabled),
           trial_days         = COALESCE(p_trial_days, trial_days),
           is_active          = COALESCE(p_is_active, is_active),
           max_partner_depots_per_shop =
               COALESCE(p_max_partner_depots, max_partner_depots_per_shop),
           max_employees_per_shop =
               COALESCE(p_max_employees_per_shop, max_employees_per_shop),
           max_warehouses     = COALESCE(p_max_warehouses, max_warehouses)
     WHERE id = p_id
     RETURNING id INTO v_id;
    IF v_id IS NULL THEN
      RAISE EXCEPTION 'plan introuvable' USING ERRCODE = 'P0002';
    END IF;
  END IF;

  SELECT email INTO v_email FROM public.profiles WHERE id::text = auth.uid()::text;
  INSERT INTO public.activity_logs
    (actor_id, actor_email, action, target_type, target_id, target_label, details)
  VALUES
    (auth.uid(), v_email,
     CASE WHEN p_id IS NULL THEN 'plan_created' ELSE 'plan_updated' END,
     'plan', v_id::text, p_label, jsonb_build_object('name', p_name));

  RETURN v_id;
END;
$upsert_plan$;
GRANT EXECUTE ON FUNCTION public.upsert_plan(
  UUID, TEXT, TEXT, NUMERIC, NUMERIC, NUMERIC, INT, INT, INT, JSONB,
  BOOLEAN, INT, BOOLEAN, INT, INT, INT) TO authenticated;

NOTIFY pgrst, 'reload schema';
