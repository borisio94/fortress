-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_099_onboarding_slides_flag.sql
--
-- Les slides d'intro marketing ne doivent s'afficher QU'UNE SEULE FOIS PAR
-- COMPTE, à la première connexion après création — et plus jamais ensuite,
-- même sur un autre appareil.
--
-- Avant : le flag « slides vues » était stocké dans SharedPreferences, donc
-- DEVICE-scoped → les slides réapparaissaient sur chaque nouvel appareil.
--
-- Après : un flag PAR COMPTE sur profiles, lu au login et invisible une fois
-- positionné, quel que soit l'appareil.
--
-- Backfill : tous les comptes EXISTANTS sont considérés déjà onboardés
-- (onboarding_slides_seen = true) → ils ne reverront pas les slides. Seuls les
-- NOUVEAUX comptes (créés après cette migration) héritent du DEFAULT false et
-- verront les slides à leur première connexion.
--
-- Le client marque le flag via un simple UPDATE (la policy RLS profiles_update
-- de hotfix_041 autorise déjà l'utilisateur à modifier son propre profil).
--
-- Idempotent : ADD COLUMN IF NOT EXISTS + backfill conditionnel.
-- ════════════════════════════════════════════════════════════════════════════

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS onboarding_slides_seen boolean NOT NULL DEFAULT false;

-- Backfill une seule fois : comptes déjà créés = déjà onboardés.
-- (Au prochain run, ces lignes sont déjà à true → no-op.)
UPDATE public.profiles
   SET onboarding_slides_seen = true
 WHERE onboarding_slides_seen = false;

NOTIFY pgrst, 'reload schema';

-- ── Vérifications (à lancer séparément) ─────────────────────────────────────
-- 1. La colonne existe avec le bon défaut :
--   SELECT column_name, data_type, column_default, is_nullable
--     FROM information_schema.columns
--    WHERE table_schema='public' AND table_name='profiles'
--      AND column_name='onboarding_slides_seen';
--   → default = false, is_nullable = NO
--
-- 2. Aucun compte existant ne reverra les slides :
--   SELECT count(*) FROM profiles WHERE onboarding_slides_seen = false;
--   → 0 juste après migration (remontera à >0 dès qu'un NOUVEAU compte est créé)
