-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_042_items_rls.sql
--
-- 🚨 HIGH — comble les 2 dernières tables avec RLS activée mais SANS policy :
--   - purchase_order_items
--   - reception_items
--
-- Sans policy, RLS = DENY ALL pour les rôles authenticated/anon. La feature
-- correspondante (lecture/écriture des items d'un bon de commande ou d'une
-- réception) ne fonctionne que via les RPC SECURITY DEFINER côté serveur.
-- Ces policies autorisent l'accès direct aux items pour tout membre actif
-- du shop du parent, en réutilisant le helper `_is_shop_member()` défini
-- dans hotfix_041 (qui inclut déjà la branche super_admin).
--
-- Modèle d'autorisation :
--   FOR ALL — SELECT/INSERT/UPDATE/DELETE
--   USING + WITH CHECK : EXISTS parent dont l'auth.uid() est membre actif
--
-- Note : `super_admin_whitelist` reste volontairement sans policy
-- (RLS-enabled + 0 policy = deny-all client). Elle n'est lue que par les
-- helpers SECURITY DEFINER (`_is_super_admin()`) qui bypassent RLS — c'est
-- exactement le pattern voulu.
--
-- 100% idempotent (DROP IF EXISTS + CREATE).
-- ════════════════════════════════════════════════════════════════════════════

-- ── purchase_order_items : héritage via purchase_orders.shop_id ────────────
DROP POLICY IF EXISTS purchase_order_items_member_all ON purchase_order_items;
CREATE POLICY purchase_order_items_member_all ON purchase_order_items
  FOR ALL TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM purchase_orders po
       WHERE po.id::text = purchase_order_items.order_id::text
         AND public._is_shop_member(po.shop_id::text)
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM purchase_orders po
       WHERE po.id::text = purchase_order_items.order_id::text
         AND public._is_shop_member(po.shop_id::text)
    )
  );

-- ── reception_items : héritage via receptions.shop_id ──────────────────────
DROP POLICY IF EXISTS reception_items_member_all ON reception_items;
CREATE POLICY reception_items_member_all ON reception_items
  FOR ALL TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM receptions r
       WHERE r.id::text = reception_items.reception_id::text
         AND public._is_shop_member(r.shop_id::text)
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM receptions r
       WHERE r.id::text = reception_items.reception_id::text
         AND public._is_shop_member(r.shop_id::text)
    )
  );


-- ── Vérification post-déploiement ──────────────────────────────────────────
-- Doit renvoyer 1 ligne par table, nb_policies = 1.
-- SELECT t.tablename, COUNT(p.policyname) AS nb_policies
--   FROM pg_tables t
--   LEFT JOIN pg_policies p
--     ON p.schemaname = t.schemaname AND p.tablename = t.tablename
--  WHERE t.schemaname = 'public'
--    AND t.tablename IN ('purchase_order_items', 'reception_items')
--  GROUP BY t.tablename;
