-- hotfix_156_order_finished.sql
-- ═════════════════════════════════════════════════════════════════════════
-- ÉTAPE « TERMINÉE » — le service est fini, l'argent ne l'est pas.
--
-- La chaîne d'états d'une commande de restaurant était amputée de son
-- avant-dernier maillon :
--
--   En préparation → Prête → Servie → ??? → Payée
--
-- « Servie » dit que l'assiette est arrivée sur la table. Il s'écoule ensuite
-- tout un repas avant que le client ne demande l'addition — et pendant ce
-- temps, rien ne distinguait une table où l'on mange d'une table où l'on a
-- fini. `finished` ferme ce trou.
--
-- UN fait, trois réalités selon le canal :
--   * sur place  — le client a fini de manger ;
--   * à emporter — il a récupéré sa commande au comptoir ;
--   * à livrer   — le livreur la lui a remise.
-- Dans les trois cas : plus rien à faire côté service, il ne reste que
-- l'encaissement.
--
-- POURQUOI PAS RÉUTILISER `status` : les statuts commerciaux (scheduled,
-- processing, completed…) pilotent le STOCK et le PAIEMENT via
-- `StockEngagement`. Y glisser un état de service ferait décrémenter un stock
-- au moment où le client repose sa fourchette. Les deux axes sont
-- indépendants, ils restent deux colonnes.
--
-- Défaut `false` : tout l'historique devient « non terminé », sans
-- conséquence — une commande déjà `completed` n'est plus jamais lue par le
-- circuit de service, et les commandes ouvertes sont par définition récentes.
--
-- 100 % idempotent (ré-exécutable sans effet de bord).
-- ═════════════════════════════════════════════════════════════════════════

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS finished BOOLEAN NOT NULL DEFAULT false;

COMMENT ON COLUMN public.orders.finished IS
  'Service TERMINÉ, encaissement non fait (hotfix_156). Sur place : le client '
  'a fini de manger. À emporter : il a récupéré. À livrer : le livreur a '
  'remis. Axe INDÉPENDANT de `status`, qui pilote stock et paiement. Remis à '
  'false si le bon repart en préparation.';

-- « Qu'est-ce qui est terminé mais pas encore encaissé ? » — la question du
-- caissier en fin de service. Index partiel : rien de clôturé n'y entre.
CREATE INDEX IF NOT EXISTS orders_finished_unpaid_idx
  ON public.orders(shop_id)
  WHERE finished AND status <> 'completed' AND deleted_at IS NULL;

-- ── Vérification ───────────────────────────────────────────────────────────
--   SELECT column_name, column_default FROM information_schema.columns
--    WHERE table_name = 'orders' AND column_name = 'finished';
--
--   -- Ce qui attend d'être encaissé en ce moment :
--   SELECT id, order_type, table_id, tab_label, total FROM public.orders
--    WHERE shop_id = '<shop>' AND finished AND status <> 'completed'
--      AND deleted_at IS NULL;
--
-- Fin — hotfix_156_order_finished.sql
