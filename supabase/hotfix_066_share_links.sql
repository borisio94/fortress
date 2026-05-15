-- ═══════════════════════════════════════════════════════════════════════════
-- hotfix_066_share_links.sql
--
-- Table de stockage des liens de partage WhatsApp avec preview personnalisée.
--
-- Flow :
--   1. App Flutter génère un token court (8 chars), insère une ligne avec :
--      - target_url : URL signée Supabase Storage du PDF facture
--      - label      : libellé custom de la boutique (« Téléchargez votre facture »)
--      - kind, shop_id, resource_id
--   2. Le message WhatsApp envoyé contient juste :
--      https://<projet>.supabase.co/functions/v1/share-preview/<token>
--   3. WhatsApp crawler fetch cette URL → l'Edge Function détecte le bot via
--      User-Agent et renvoie un HTML avec <meta og:title> = label.
--   4. Vrai navigateur → 302 redirect vers target_url.
--
-- Sécurité :
--   • Token random 8 chars → 30^8 ≈ 6.5e11 combinaisons. Collision improbable.
--   • Expiration obligatoire (par défaut 30 jours dans le client).
--   • RLS : insertion réservée aux membres de la boutique. Lecture publique
--     (l'Edge Function lit via service_role_key bypass RLS — mais on autorise
--     `SELECT` pour permettre debug/admin si besoin).
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.share_links (
  token        TEXT PRIMARY KEY,
  kind         TEXT NOT NULL CHECK (kind IN
                  ('invoice', 'order_reminder', 'catalogue', 'news', 'promo')),
  shop_id      UUID NOT NULL,
  resource_id  TEXT,
  target_url   TEXT NOT NULL,
  label        TEXT NOT NULL,
  description  TEXT,
  image_url    TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at   TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_share_links_shop_id ON public.share_links(shop_id);
CREATE INDEX IF NOT EXISTS idx_share_links_expires_at ON public.share_links(expires_at);

ALTER TABLE public.share_links ENABLE ROW LEVEL SECURITY;

-- INSERT : membres actifs de la boutique
DROP POLICY IF EXISTS share_links_insert ON public.share_links;
CREATE POLICY share_links_insert ON public.share_links
  FOR INSERT TO authenticated
  WITH CHECK (
    shop_id::text IN (
      SELECT shop_id FROM public.shop_memberships
      WHERE user_id = auth.uid()::text
    )
  );

-- SELECT : autorisé pour debug/admin. L'Edge Function bypasse via service_role.
DROP POLICY IF EXISTS share_links_select ON public.share_links;
CREATE POLICY share_links_select ON public.share_links
  FOR SELECT TO authenticated
  USING (
    shop_id::text IN (
      SELECT shop_id FROM public.shop_memberships
      WHERE user_id = auth.uid()::text
    )
  );

-- DELETE : owner/admin uniquement (pour purger d'anciens liens si besoin).
DROP POLICY IF EXISTS share_links_delete ON public.share_links;
CREATE POLICY share_links_delete ON public.share_links
  FOR DELETE TO authenticated
  USING (
    shop_id::text IN (
      SELECT shop_id FROM public.shop_memberships
      WHERE user_id = auth.uid()::text AND role IN ('owner', 'admin')
    )
  );

-- Nettoyage automatique des liens expirés (à appeler via cron / pg_cron).
CREATE OR REPLACE FUNCTION public.cleanup_expired_share_links()
RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  deleted_count INTEGER;
BEGIN
  DELETE FROM public.share_links
   WHERE expires_at IS NOT NULL AND expires_at < NOW();
  GET DIAGNOSTICS deleted_count = ROW_COUNT;
  RETURN deleted_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.cleanup_expired_share_links() TO authenticated;
