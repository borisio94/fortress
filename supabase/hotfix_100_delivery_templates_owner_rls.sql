-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_100_delivery_templates_owner_rls.sql
--
-- Bug : créer un template de livraison échoue avec
--   « new row violates row-level security policy for table
--     "delivery_templates" » (code 42501).
--
-- Cause : la policy `delivery_templates_members` (hotfix_049) vérifie
-- UNIQUEMENT une ligne dans `shop_memberships` :
--   WITH CHECK (EXISTS (SELECT 1 FROM shop_memberships m
--                WHERE m.shop_id = delivery_templates.shop_id
--                  AND m.user_id = auth.uid()::text))
-- Or le PROPRIÉTAIRE d'une boutique (shops.owner_id) n'a pas forcément de
-- ligne `shop_memberships` (l'appartenance directe passe par owner_id). Il est
-- donc rejeté à l'INSERT/UPDATE de ses propres templates.
--
-- Correctif : aligner la policy sur le helper canonique `_is_shop_member`
-- (hotfix_041) qui couvre owner direct OU membre actif OU super-admin —
-- exactement le même pattern que products/orders/clients/shops.
--
-- Idempotent : DROP + CREATE.
-- ════════════════════════════════════════════════════════════════════════════

DROP POLICY IF EXISTS delivery_templates_members ON public.delivery_templates;
CREATE POLICY delivery_templates_members ON public.delivery_templates
  FOR ALL TO authenticated
  USING      (public._is_shop_member(shop_id::text))
  WITH CHECK (public._is_shop_member(shop_id::text));

NOTIFY pgrst, 'reload schema';

-- ── Vérification (à lancer séparément) ──────────────────────────────────────
-- SELECT polname, cmd, qual, with_check
--   FROM pg_policies
--  WHERE tablename = 'delivery_templates';
--   → delivery_templates_members doit référencer _is_shop_member
