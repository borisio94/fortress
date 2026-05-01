-- ═══════════════════════════════════════════════════════════════════════════
-- Fortress — Migration 002 : accès admin boutique aux activity_logs
-- Ajoute deux policies permettant à un admin ou propriétaire de boutique de
-- lire l'historique des actions auditées sur sa propre boutique.
--
-- Tous les identifiants sont comparés en TEXT pour éviter les divergences
-- de typage entre tables (shops.id en TEXT, activity_logs.shop_id en UUID,
-- shop_memberships.user_id en TEXT, auth.uid() en UUID).
-- ═══════════════════════════════════════════════════════════════════════════

DROP POLICY IF EXISTS activity_logs_shop_admin_read ON activity_logs;
CREATE POLICY activity_logs_shop_admin_read ON activity_logs
  FOR SELECT USING (
    shop_id IS NOT NULL
    AND shop_id::text IN (
      SELECT shop_id::text FROM shop_memberships
      WHERE user_id::text = (auth.uid())::text AND role = 'admin'
    )
  );

DROP POLICY IF EXISTS activity_logs_shop_owner_read ON activity_logs;
CREATE POLICY activity_logs_shop_owner_read ON activity_logs
  FOR SELECT USING (
    shop_id IS NOT NULL
    AND shop_id::text IN (
      SELECT id::text FROM shops
      WHERE owner_id::text = (auth.uid())::text
    )
  );
