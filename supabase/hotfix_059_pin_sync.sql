-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_059_pin_sync.sql
--
-- Ajoute `pin_hash` + `pin_salt` à la table `profiles` pour synchroniser
-- le code PIN propriétaire entre les devices d'un même compte.
--
-- Avant : `PinService` stockait hash+sel uniquement dans SecureStorage local
-- (KeyStore Android / Keychain iOS / IndexedDB chiffré web). Conséquence :
-- un PIN configuré sur le desktop n'existait pas sur mobile (et vice versa),
-- l'utilisateur devait le re-configurer sur chaque device.
--
-- Sécurité : on stocke uniquement le hash SHA-256 (sel||pin), jamais le PIN
-- en clair. Le sel est aussi remoté pour permettre la vérification
-- déterministe sur tout device. La RLS existante sur `profiles` (chaque
-- user voit/modifie uniquement son propre row) protège ces colonnes.
-- ════════════════════════════════════════════════════════════════════════════

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS pin_hash TEXT;

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS pin_salt TEXT;

-- Pas d'index utile : les colonnes ne sont jamais filtrées en SELECT,
-- on les charge avec le row du profil au login.

COMMENT ON COLUMN public.profiles.pin_hash IS
  'SHA-256(salt || pin) du code PIN owner (4 chiffres). Jamais le PIN clair.';
COMMENT ON COLUMN public.profiles.pin_salt IS
  'Sel aléatoire 16 octets (base64url) utilisé pour hasher le PIN.';
