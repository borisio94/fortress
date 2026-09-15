-- hotfix_163_receptions_costing.sql
-- ═════════════════════════════════════════════════════════════════════════
-- L'ARRIVAGE GROUPÉ VALORISÉ — un lot, plusieurs modèles, un coût global.
--
-- Une arrivée de stock arrive en UN SEUL BLOC : plusieurs produits
-- différents, et des frais (transport, douane, manutention) payés pour le
-- lot entier, impossibles à rattacher à un modèle en particulier. Le
-- catalogue, lui, ne sait porter un coût que produit par produit
-- (`products.price_buy`) — d'où l'impasse : il fallait inventer une
-- ventilation à la main avant de pouvoir saisir quoi que ce soit.
--
-- Le bon de réception devient donc le document qui porte l'argent :
--   * `fees`  — les frais du lot, répartis à parts égales sur chaque PIÈCE
--               reçue (une pièce transportée supporte le même transport
--               qu'une autre, quelle que soit sa valeur marchande) ;
--   * `items` — les lignes, chacune avec son prix d'achat unitaire
--               (`unit_cost`) et son coût de revient figé à la validation
--               (`landed_unit_cost` = unit_cost + frais/pièce).
-- À la validation, ce coût de revient est absorbé dans le `price_buy` du
-- produit en moyenne pondérée avec le stock déjà présent.
--
-- POURQUOI `items` EN JSONB alors que `reception_items` existe :
-- l'entité Dart sérialise déjà ses lignes dans le map du bon (`toMap()`),
-- et c'est ce map que la synchro passthrough pousse et relit tel quel. Sans
-- cette colonne, l'upsert partait en erreur sur une colonne inconnue et le
-- bon restait prisonnier du Hive de l'appareil qui l'avait saisi — purgé au
-- premier `syncReceptions` (la synchro efface le local absent du distant).
-- `reception_items` reste en place pour les bons historiques.
--
-- `schema_version` : les entités Dart écrivent ce champ dans leur map
-- (cf. lib/core/storage/schema_migrator.dart) ; sans la colonne, l'upsert
-- est rejeté.
--
-- 100 % idempotent (ré-exécutable sans effet de bord).
-- ═════════════════════════════════════════════════════════════════════════

ALTER TABLE public.receptions
  ADD COLUMN IF NOT EXISTS schema_version INTEGER,
  ADD COLUMN IF NOT EXISTS items          JSONB NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS fees           JSONB NOT NULL DEFAULT '[]'::jsonb;

COMMENT ON COLUMN public.receptions.items IS
  'Lignes du bon (product_id, variant_id, quantités, unit_cost, '
  'landed_unit_cost). Miroir de ReceptionItem.toMap().';
COMMENT ON COLUMN public.receptions.fees IS
  'Frais du LOT : [{"label":"Transport","amount":10000}, …]. Répartis à '
  'parts égales par pièce reçue, jamais au prorata de la valeur.';

-- Les bons antérieurs à la valorisation avaient leurs lignes dans
-- `reception_items` : on les recopie dans le JSONB pour que la synchro les
-- rende de nouveau lisibles par l'application. `unit_cost` /
-- `landed_unit_cost` restent à 0 — aucun coût n'est inventé rétroactivement.
UPDATE public.receptions r
SET    items = sub.items
FROM (
  SELECT ri.reception_id,
         jsonb_agg(jsonb_build_object(
           'id',            ri.id,
           'product_id',    ri.product_id,
           'variant_id',    ri.variant_id,
           'product_name',  ri.product_name,
           'expected_qty',  ri.expected_qty,
           'received_qty',  ri.received_qty,
           'damaged_qty',   ri.damaged_qty,
           'defective_qty', ri.defective_qty,
           'status',        ri.status,
           'notes',         ri.notes,
           'unit_cost',        0,
           'landed_unit_cost', 0
         ) ORDER BY ri.id) AS items
  FROM   public.reception_items ri
  GROUP  BY ri.reception_id
) sub
WHERE  r.id = sub.reception_id
  AND  (r.items IS NULL OR r.items = '[]'::jsonb);

-- Realtime : la table est déjà publiée (hotfix_074), mais on le refait par
-- sécurité si la publication a été recréée depuis.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE  pubname = 'supabase_realtime'
      AND  schemaname = 'public'
      AND  tablename  = 'receptions'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.receptions;
  END IF;
END $$;
