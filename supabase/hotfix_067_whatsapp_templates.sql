-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_067_whatsapp_templates.sql
--
-- Système CRUD de templates de messages WhatsApp envoyés aux clients, calqué
-- sur delivery_templates (hotfix_049) mais avec un champ `type` pour ranger
-- par cas d'usage (facture, relance commande, catalogue, nouveautés, promo).
--
-- Chaque shop peut avoir N templates par type, avec UN SEUL défaut par type.
-- Le placeholder `{{variable}}` dans body est remplacé au moment de l'envoi
-- par WhatsappTemplateRenderer.
--
-- Idempotent. Compatible hotfix_043 (SECURITY DEFINER + search_path verrouillé).
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. Table whatsapp_templates ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.whatsapp_templates (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id     text NOT NULL REFERENCES public.shops(id) ON DELETE CASCADE,
  type        text NOT NULL CHECK (type IN
                ('invoice', 'order_reminder', 'catalogue', 'news', 'promo')),
  name        text NOT NULL,
  body        text NOT NULL,
  is_default  bool NOT NULL DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT  whatsapp_templates_name_per_shop UNIQUE (shop_id, name)
);

-- Garde anti-doublon : si plusieurs is_default=true coexistent déjà pour le
-- même (shop_id, type), on ne garde que le plus ancien.
WITH ranked AS (
  SELECT id,
         ROW_NUMBER() OVER (PARTITION BY shop_id, type ORDER BY created_at) AS rn
    FROM public.whatsapp_templates
   WHERE is_default = true
)
UPDATE public.whatsapp_templates t
   SET is_default = false
  FROM ranked r
 WHERE t.id = r.id AND r.rn > 1;

-- Un seul défaut par (shop_id, type).
CREATE UNIQUE INDEX IF NOT EXISTS whatsapp_templates_default_uniq
  ON public.whatsapp_templates (shop_id, type) WHERE is_default = true;

CREATE INDEX IF NOT EXISTS whatsapp_templates_shop_type_idx
  ON public.whatsapp_templates (shop_id, type, created_at DESC);

-- ── 2. RLS ──────────────────────────────────────────────────────────────────
ALTER TABLE public.whatsapp_templates ENABLE ROW LEVEL SECURITY;

-- SELECT : tout membre actif du shop
DROP POLICY IF EXISTS whatsapp_templates_select ON public.whatsapp_templates;
CREATE POLICY whatsapp_templates_select ON public.whatsapp_templates
  FOR SELECT TO authenticated
  USING (
    shop_id IN (
      SELECT shop_id FROM public.shop_memberships
      WHERE user_id = auth.uid()::text
    )
  );

-- INSERT / UPDATE / DELETE : admins/owners du shop
DROP POLICY IF EXISTS whatsapp_templates_insert ON public.whatsapp_templates;
CREATE POLICY whatsapp_templates_insert ON public.whatsapp_templates
  FOR INSERT TO authenticated
  WITH CHECK (
    shop_id IN (
      SELECT shop_id FROM public.shop_memberships
      WHERE user_id = auth.uid()::text
        AND role IN ('owner', 'admin')
    )
  );

DROP POLICY IF EXISTS whatsapp_templates_update ON public.whatsapp_templates;
CREATE POLICY whatsapp_templates_update ON public.whatsapp_templates
  FOR UPDATE TO authenticated
  USING (
    shop_id IN (
      SELECT shop_id FROM public.shop_memberships
      WHERE user_id = auth.uid()::text
        AND role IN ('owner', 'admin')
    )
  );

DROP POLICY IF EXISTS whatsapp_templates_delete ON public.whatsapp_templates;
CREATE POLICY whatsapp_templates_delete ON public.whatsapp_templates
  FOR DELETE TO authenticated
  USING (
    shop_id IN (
      SELECT shop_id FROM public.shop_memberships
      WHERE user_id = auth.uid()::text
        AND role IN ('owner', 'admin')
    )
  );

COMMIT;
