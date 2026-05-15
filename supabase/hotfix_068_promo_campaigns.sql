-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_068_promo_campaigns.sql
--
-- Système de campagnes marketing (promotions + annonces nouveautés) envoyées
-- aux clients via WhatsApp. Chaque campagne contient un snapshot des produits
-- au moment de la création — la page publique `/promo/:shopId/:campaignId`
-- reste cohérente même si l'admin modifie les produits par la suite.
--
-- Flow :
--   1. Admin crée une campagne (type, nom, produits, remise %).
--   2. Sélectionne les destinataires (clients du shop).
--   3. Envoi séquentiel WhatsApp : wa.me ouvert un par un, message templaté
--      + lien court vers la vitrine. `sent_count` incrémenté à chaque envoi.
--   4. Client clique sur le lien → page publique vitrine → bouton "Commander"
--      qui mène au catalogue public avec panier pré-rempli.
--
-- Sécurité :
--   • SELECT public : nécessaire pour que la vitrine soit accessible sans auth.
--     Aucune donnée sensible (juste des produits déjà publics dans le catalogue).
--   • INSERT/UPDATE/DELETE : admins/owners du shop uniquement.
--
-- Idempotent.
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE TABLE IF NOT EXISTS public.promo_campaigns (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id           text NOT NULL REFERENCES public.shops(id) ON DELETE CASCADE,
  type              text NOT NULL CHECK (type IN ('promo', 'news')),
  name              text NOT NULL,
  -- Snapshot des produits inclus. Format : array d'objets
  -- { product_id, variant_id?, name, image_url?, original_price,
  --   promo_price?, discount_percent? }
  products          jsonb NOT NULL DEFAULT '[]'::jsonb,
  -- Remise globale en % (peut s'appliquer à tous les produits si individuel
  -- non défini). Null = pas de remise globale (cas news).
  discount_percent  integer,
  -- Date limite de validité (affichée dans la vitrine). Null = pas de limite.
  valid_until       timestamptz,
  -- Description libre (optionnelle). Texte court affiché sur la vitrine.
  description       text,
  -- Analytics : compteur d'envois (incrémenté à chaque wa.me ouvert) et de
  -- vues (incrémenté à chaque GET sur la vitrine).
  sent_count        integer NOT NULL DEFAULT 0,
  view_count        integer NOT NULL DEFAULT 0,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS promo_campaigns_shop_idx
  ON public.promo_campaigns (shop_id, created_at DESC);

CREATE INDEX IF NOT EXISTS promo_campaigns_type_idx
  ON public.promo_campaigns (shop_id, type);

ALTER TABLE public.promo_campaigns ENABLE ROW LEVEL SECURITY;

-- SELECT public : la vitrine `/promo/:shopId/:campaignId` est anonyme.
-- Pas de leak : on n'expose que des produits déjà visibles dans le catalogue
-- public du shop.
DROP POLICY IF EXISTS promo_campaigns_select_public ON public.promo_campaigns;
CREATE POLICY promo_campaigns_select_public ON public.promo_campaigns
  FOR SELECT TO anon, authenticated
  USING (true);

-- INSERT / UPDATE / DELETE : owners + admins du shop uniquement.
DROP POLICY IF EXISTS promo_campaigns_insert ON public.promo_campaigns;
CREATE POLICY promo_campaigns_insert ON public.promo_campaigns
  FOR INSERT TO authenticated
  WITH CHECK (
    shop_id IN (
      SELECT shop_id FROM public.shop_memberships
      WHERE user_id = auth.uid()::text
        AND role IN ('owner', 'admin')
    )
  );

DROP POLICY IF EXISTS promo_campaigns_update ON public.promo_campaigns;
CREATE POLICY promo_campaigns_update ON public.promo_campaigns
  FOR UPDATE TO authenticated
  USING (
    shop_id IN (
      SELECT shop_id FROM public.shop_memberships
      WHERE user_id = auth.uid()::text
        AND role IN ('owner', 'admin')
    )
  );

DROP POLICY IF EXISTS promo_campaigns_delete ON public.promo_campaigns;
CREATE POLICY promo_campaigns_delete ON public.promo_campaigns
  FOR DELETE TO authenticated
  USING (
    shop_id IN (
      SELECT shop_id FROM public.shop_memberships
      WHERE user_id = auth.uid()::text
        AND role IN ('owner', 'admin')
    )
  );

-- ── RPC : incrément atomique de sent_count et view_count ──────────────────
-- Permettent l'incrément sans nécessiter UPDATE pour anon (vitrine publique).
CREATE OR REPLACE FUNCTION public.increment_promo_sent(campaign_id uuid)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  UPDATE public.promo_campaigns
     SET sent_count = sent_count + 1
   WHERE id = campaign_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.increment_promo_sent(uuid)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.increment_promo_view(campaign_id uuid)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  UPDATE public.promo_campaigns
     SET view_count = view_count + 1
   WHERE id = campaign_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.increment_promo_view(uuid)
  TO anon, authenticated;

COMMIT;
