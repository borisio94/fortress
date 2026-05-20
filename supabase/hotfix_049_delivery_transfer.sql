-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_049_delivery_transfer.sql
--
-- Feature : Transfert d'une commande "scheduled" → "processing" via WhatsApp,
-- avec template configurable par boutique et attribuable par destinataire
-- (partenaire de livraison ou employé). Audit immutable.
--
-- IMPORTANT — types des FK (vérifiés par essai/erreur sur prod) :
--   • shops.id      est `text` → `shop_id text REFERENCES shops(id)`.
--   • orders.id     est `text` également → `order_id text REFERENCES orders(id)`.
--   • auth.users.id est `uuid` natif Supabase → `sender_user_id uuid`.
--   • delivery_templates.id (que cette migration crée) est `uuid` → les
--     attributions sur stock_locations / shop_memberships utilisent `uuid`.
--
-- Tables créées :
--   • delivery_templates       (modèles de message {{variable}})
--   • delivery_transfers       (audit immutable des envois)
--
-- Colonnes ajoutées :
--   • stock_locations.delivery_template_id   (FK templates, ON DELETE SET NULL)
--   • shop_memberships.delivery_template_id  (FK templates, ON DELETE SET NULL)
--
-- RPC : transfer_order_to_delivery (atomique, vérifie perm serveur via
--       _user_has_permission de hotfix_039 — clé `delivery.send_whatsapp`).
--
-- Trigger : seed du template par défaut à la création d'un shop.
-- Backfill : seed pour les shops existants sans template.
--
-- Idempotent. Conforme hotfix_043 (SECURITY DEFINER + search_path verrouillé).
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. Templates de livraison ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS delivery_templates (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id     text NOT NULL REFERENCES shops(id) ON DELETE CASCADE,
  name        text NOT NULL,
  body        text NOT NULL,
  is_default  bool NOT NULL DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT  delivery_templates_name_per_shop UNIQUE (shop_id, name)
);

-- Garde anti-doublon avant d'imposer l'index unique partiel : si plusieurs
-- is_default=true coexistent déjà (manipulation manuelle, race), on ne
-- garde que le plus ancien.
WITH ranked AS (
  SELECT id,
         ROW_NUMBER() OVER (PARTITION BY shop_id ORDER BY created_at) AS rn
    FROM delivery_templates
   WHERE is_default = true
)
UPDATE delivery_templates t
   SET is_default = false
  FROM ranked r
 WHERE t.id = r.id AND r.rn > 1;

CREATE UNIQUE INDEX IF NOT EXISTS delivery_templates_default_uniq
  ON delivery_templates (shop_id) WHERE is_default = true;

CREATE INDEX IF NOT EXISTS delivery_templates_shop_idx
  ON delivery_templates (shop_id, created_at DESC);

-- ── 2. Attribution template ↔ destinataire ───────────────────────────────────
ALTER TABLE stock_locations
  ADD COLUMN IF NOT EXISTS delivery_template_id uuid;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'stock_locations_template_fk'
  ) THEN
    ALTER TABLE stock_locations
      ADD CONSTRAINT stock_locations_template_fk
      FOREIGN KEY (delivery_template_id)
      REFERENCES delivery_templates(id) ON DELETE SET NULL;
  END IF;
END $$;

ALTER TABLE shop_memberships
  ADD COLUMN IF NOT EXISTS delivery_template_id uuid;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'shop_memberships_template_fk'
  ) THEN
    ALTER TABLE shop_memberships
      ADD CONSTRAINT shop_memberships_template_fk
      FOREIGN KEY (delivery_template_id)
      REFERENCES delivery_templates(id) ON DELETE SET NULL;
  END IF;
END $$;

-- ── 3. Audit immutable des transferts ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS delivery_transfers (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id         text NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  shop_id          text NOT NULL REFERENCES shops(id)  ON DELETE CASCADE,
  sender_user_id   uuid NOT NULL REFERENCES auth.users(id),
  -- Destinataire : 'partner' | 'employee' | 'free'
  target_type      text NOT NULL CHECK (target_type IN ('partner','employee','free')),
  -- stock_location.id (partner), user_id (employee), ou NULL (free)
  target_ref       text,
  target_name      text NOT NULL,
  target_phone     text NOT NULL,            -- format E.164
  template_id      uuid REFERENCES delivery_templates(id) ON DELETE SET NULL,
  message_snapshot text NOT NULL,            -- exactement ce qui a été envoyé
  created_at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS delivery_transfers_order_idx
  ON delivery_transfers (order_id, created_at DESC);

CREATE INDEX IF NOT EXISTS delivery_transfers_shop_idx
  ON delivery_transfers (shop_id, created_at DESC);

-- ── 4. RLS ───────────────────────────────────────────────────────────────────
-- Note : `shop_memberships.user_id` est `text` dans cette codebase
--        (cf. hotfix_010/011/014 : `user_id = auth.uid()::text`). On caste
--        donc auth.uid() (uuid) en text pour la comparaison.

ALTER TABLE delivery_templates  ENABLE ROW LEVEL SECURITY;
ALTER TABLE delivery_transfers  ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS delivery_templates_members ON delivery_templates;
CREATE POLICY delivery_templates_members ON delivery_templates
  USING      (EXISTS (SELECT 1 FROM shop_memberships m
                       WHERE m.shop_id = delivery_templates.shop_id
                         AND m.user_id = auth.uid()::text))
  WITH CHECK (EXISTS (SELECT 1 FROM shop_memberships m
                       WHERE m.shop_id = delivery_templates.shop_id
                         AND m.user_id = auth.uid()::text));

DROP POLICY IF EXISTS delivery_transfers_members ON delivery_transfers;
CREATE POLICY delivery_transfers_members ON delivery_transfers
  FOR SELECT USING (EXISTS (SELECT 1 FROM shop_memberships m
                             WHERE m.shop_id = delivery_transfers.shop_id
                               AND m.user_id = auth.uid()::text));

-- INSERT/UPDATE/DELETE sur delivery_transfers passent UNIQUEMENT par la RPC
-- (SECURITY DEFINER) — pas de policy permissive.

COMMIT;

-- ── 5. RPC atomique ──────────────────────────────────────────────────────────
-- Vérifie perm `delivery.send_whatsapp` côté serveur via
-- `_user_has_permission` (hotfix_039) :
--   • owner du shop  → bypass total
--   • super_admin    → bypass total
--   • role 'admin'   → autorisé par défaut (admin = toutes perms sauf
--                       owner-only ; cette key n'est pas owner-only)
--   • role 'user'    → REFUSÉ par défaut, requiert un grant explicite
--                       `delivery.send_whatsapp` dans le JSONB de la
--                       membership (configurable depuis la fiche RH)
--   • `deny:delivery.send_whatsapp` bloque même un grant.

CREATE OR REPLACE FUNCTION public.transfer_order_to_delivery(
  p_order_id         text,
  p_target_type      text,
  p_target_ref       text,
  p_target_name      text,
  p_target_phone     text,
  p_template_id      uuid,
  p_message_snapshot text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_shop_id     text;
  v_status      text;
  v_user_id     uuid := auth.uid();
  v_transfer_id uuid := gen_random_uuid();
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = '42501';
  END IF;
  IF p_target_type NOT IN ('partner','employee','free') THEN
    RAISE EXCEPTION 'target_type_invalid' USING ERRCODE = '22023';
  END IF;
  IF p_target_phone !~ '^\+[1-9][0-9]{6,14}$' THEN
    RAISE EXCEPTION 'phone_invalid_e164' USING ERRCODE = '22023';
  END IF;
  IF length(trim(coalesce(p_target_name, ''))) = 0 THEN
    RAISE EXCEPTION 'target_name_required' USING ERRCODE = '22023';
  END IF;
  IF length(trim(coalesce(p_message_snapshot, ''))) = 0 THEN
    RAISE EXCEPTION 'message_required' USING ERRCODE = '22023';
  END IF;

  SELECT shop_id, status INTO v_shop_id, v_status
    FROM orders WHERE id = p_order_id;
  IF v_shop_id IS NULL THEN
    RAISE EXCEPTION 'order_not_found' USING ERRCODE = '42P01';
  END IF;
  IF v_status <> 'scheduled' THEN
    RAISE EXCEPTION 'order_not_scheduled' USING ERRCODE = '22023';
  END IF;

  -- Vérification serveur de la permission `delivery.send_whatsapp`.
  -- Réutilise le helper hotfix_039 (owner / super_admin / role+grant/deny).
  IF NOT public._user_has_permission(v_shop_id, 'delivery.send_whatsapp') THEN
    RAISE EXCEPTION 'delivery_transfer_forbidden' USING ERRCODE = '42501';
  END IF;

  UPDATE orders SET status = 'processing' WHERE id = p_order_id;

  INSERT INTO delivery_transfers
    (id, order_id, shop_id, sender_user_id, target_type, target_ref,
     target_name, target_phone, template_id, message_snapshot, created_at)
  VALUES
    (v_transfer_id, p_order_id, v_shop_id, v_user_id, p_target_type,
     NULLIF(trim(coalesce(p_target_ref, '')), ''),
     trim(p_target_name), p_target_phone,
     p_template_id, p_message_snapshot, now());

  RETURN v_transfer_id;
END;
$fn$;

REVOKE ALL ON FUNCTION public.transfer_order_to_delivery(
    text, text, text, text, text, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.transfer_order_to_delivery(
    text, text, text, text, text, uuid, text) TO authenticated;

-- ── 6. Trigger : seed du template par défaut à la création d'un shop ─────────
CREATE OR REPLACE FUNCTION public._seed_default_delivery_template()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
BEGIN
  INSERT INTO delivery_templates (shop_id, name, body, is_default)
  VALUES (NEW.id::text, 'Format par défaut',
    '🛵 Nouvelle livraison — {{caisse}}'||E'\n\n'||
    'Client : {{client_name}}'||E'\n'||
    'Tél    : {{client_phone}}'||E'\n'||
    'Lieu   : {{lieu_livraison}}'||E'\n\n'||
    'Produits :'||E'\n'||'{{produits}}'||E'\n\n'||
    'Date prévue : {{date}} à {{heure}}'||E'\n\n'||
    'Prix produits  : {{prix_produit}}'||E'\n'||
    'Frais livraison: {{frais_livraison}}'||E'\n'||
    'Total à percevoir : {{total}}'||E'\n\n'||
    'Notes : {{notes}}',
    true)
  ON CONFLICT DO NOTHING;
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS shops_seed_delivery_template ON shops;
CREATE TRIGGER shops_seed_delivery_template
  AFTER INSERT ON shops
  FOR EACH ROW EXECUTE FUNCTION public._seed_default_delivery_template();

-- ── 7. Backfill : seed pour les shops existants sans template ────────────────
INSERT INTO delivery_templates (shop_id, name, body, is_default)
SELECT s.id::text, 'Format par défaut',
  '🛵 Nouvelle livraison — {{caisse}}'||E'\n\n'||
  'Client : {{client_name}}'||E'\n'||
  'Tél    : {{client_phone}}'||E'\n'||
  'Lieu   : {{lieu_livraison}}'||E'\n\n'||
  'Produits :'||E'\n'||'{{produits}}'||E'\n\n'||
  'Date prévue : {{date}} à {{heure}}'||E'\n\n'||
  'Prix produits  : {{prix_produit}}'||E'\n'||
  'Frais livraison: {{frais_livraison}}'||E'\n'||
  'Total à percevoir : {{total}}'||E'\n\n'||
  'Notes : {{notes}}',
  true
FROM shops s
WHERE NOT EXISTS (
  SELECT 1 FROM delivery_templates t WHERE t.shop_id = s.id::text
);
