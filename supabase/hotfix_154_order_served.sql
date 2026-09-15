-- hotfix_154_order_served.sql
-- ═════════════════════════════════════════════════════════════════════════
-- PHASE 6 DU CYCLE DE COMMANDE — « SERVIE ».
--
-- `orders.served` distingue deux moments que l'application confondait :
--   * `kitchen_ready` — la cuisine a fini, l'assiette est au passe ;
--   * `served`        — le serveur l'a APPORTÉE au client.
--
-- Entre les deux, il s'écoule un temps pendant lequel le plat refroidit sans
-- que personne ne soit alerté : la cuisine est passée à la commande suivante,
-- et la salle ne sait pas qu'il y a quelque chose à prendre. C'est ce trou que
-- la colonne ferme — le plan de salle fait ressortir en orange toute table
-- dont un bon est prêt et non servi.
--
-- Défaut `false` : tout l'historique devient « non servi », ce qui est sans
-- conséquence — seules les commandes OUVERTES et `kitchen_ready` allument le
-- signal, et elles sont par définition récentes.
--
-- 100 % idempotent (ré-exécutable sans effet de bord).
-- ═════════════════════════════════════════════════════════════════════════

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS served BOOLEAN NOT NULL DEFAULT false;

COMMENT ON COLUMN public.orders.served IS
  'Plats APPORTÉS au client (hotfix_154). Distinct de kitchen_ready, qui ne '
  'dit que la fin de la préparation. Remis à false quand un bon est renvoyé '
  'en cuisine ou redéclaré prêt, pour que la salle soit ré-alertée.';

-- Le plan de salle cherche « les bons prêts et non servis » d'une boutique.
-- Index partiel : les commandes déjà servies ou clôturées n'y entrent pas.
CREATE INDEX IF NOT EXISTS orders_waiting_service_idx
  ON public.orders(shop_id)
  WHERE kitchen_ready AND NOT served AND deleted_at IS NULL;

-- ── Vérification ───────────────────────────────────────────────────────────
--   SELECT column_name, column_default FROM information_schema.columns
--    WHERE table_name = 'orders' AND column_name = 'served';
--
--   -- Ce qui attend au passe en ce moment :
--   SELECT id, table_id, tab_label FROM public.orders
--    WHERE shop_id = '<shop>' AND kitchen_ready AND NOT served
--      AND deleted_at IS NULL;
--
-- Fin — hotfix_154_order_served.sql
