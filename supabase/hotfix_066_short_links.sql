-- ═══════════════════════════════════════════════════════════════════════════
-- hotfix_066_short_links.sql
--
-- Raccourcisseur d'URL maison pour les liens envoyés aux clients via WhatsApp
-- (factures, relances, catalogues, etc.). Remplace TinyURL : URLs plus courtes,
-- contrôle total, stats de clics, expiration.
--
-- Flow :
--   1. App Flutter appelle `generate_short_slug()` → slug 6 chars unique
--   2. INSERT dans short_links avec long_url + link_type + expires_at
--   3. URL envoyée au client : https://<projet>.supabase.co/functions/v1/r/<slug>
--   4. Au clic, Edge Function `r` résout slug → 302 vers long_url + incr clicks
--
-- Sécurité :
--   • RLS SELECT public (anon + authenticated) — nécessaire pour que l'Edge
--     Function puisse résoudre sans service_role
--   • INSERT réservé aux utilisateurs authentifiés
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.short_links (
  slug         TEXT PRIMARY KEY,
  long_url     TEXT NOT NULL,
  link_type    TEXT NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at   TIMESTAMPTZ,
  click_count  INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_short_links_type    ON public.short_links(link_type);
CREATE INDEX IF NOT EXISTS idx_short_links_expires ON public.short_links(expires_at);

ALTER TABLE public.short_links ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS short_links_select ON public.short_links;
CREATE POLICY short_links_select ON public.short_links
  FOR SELECT TO anon, authenticated
  USING (expires_at IS NULL OR expires_at > NOW());

DROP POLICY IF EXISTS short_links_insert ON public.short_links;
CREATE POLICY short_links_insert ON public.short_links
  FOR INSERT TO authenticated WITH CHECK (true);

-- ── generate_short_slug() : retourne un slug 6 chars unique ──────────────
-- Alphabet 36 chars (a-z + 0-9) → 36^6 = 2.18 milliards de combinaisons.
-- Collision improbable avant des millions de liens. Boucle au cas où.
CREATE OR REPLACE FUNCTION public.generate_short_slug()
RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE
  chars        TEXT := 'abcdefghijklmnopqrstuvwxyz0123456789';
  result       TEXT;
  i            INTEGER;
  exists_check INTEGER;
BEGIN
  LOOP
    result := '';
    FOR i IN 1..6 LOOP
      result := result || substr(chars,
                                 floor(random() * length(chars) + 1)::int,
                                 1);
    END LOOP;
    SELECT COUNT(*) INTO exists_check
      FROM public.short_links WHERE slug = result;
    EXIT WHEN exists_check = 0;
  END LOOP;
  RETURN result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.generate_short_slug() TO authenticated;

-- ── increment_link_click() : compteur de clics (analytics) ───────────────
-- SECURITY DEFINER pour permettre l'incrément depuis l'Edge Function avec
-- la clé anon (qui n'a normalement pas UPDATE sur short_links).
CREATE OR REPLACE FUNCTION public.increment_link_click(link_slug TEXT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  UPDATE public.short_links
     SET click_count = click_count + 1
   WHERE slug = link_slug;
END;
$$;

GRANT EXECUTE ON FUNCTION public.increment_link_click(TEXT) TO anon, authenticated;
