-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_176_stock_movements_schema_align.sql
--
-- STK-2 (vague 3 de l'audit du parcours de commande) — aligner le schéma de
-- `stock_movements` sur ce que le client écrit RÉELLEMENT.
--
-- CONSTAT : `stock_movements` est synchronisée en PASSTHROUGH — la purge
-- efface toute ligne Hive absente du distant. `StockService._log` ne faisait
-- qu'un `put` Hive sans jamais pousser : aucune opération en file, donc aucune
-- protection, donc purge garantie à la première synchronisation. Le commit
-- `caf84ba` a ajouté le push manquant (`AppDatabase.bgUpsert`) — mais ce push
-- ne pouvait PAS aboutir, et son message affirme à tort qu'il refermait le
-- trou.
--
-- POURQUOI IL NE POUVAIT PAS ABOUTIR : la map de `_log` porte 18 clés, la
-- table n'en a que 12. NEUF clés n'existent pas côté serveur —
--   before_available, after_available, before_blocked, after_blocked,
--   before_physical, after_physical, status, cause
-- et `reference_id`, dont la colonne s'appelle en réalité `reference`.
-- Résultat : PGRST204 (colonne inconnue) à chaque push. Et 8 des types écrits
-- violent en plus le CHECK (23514). Or, d'après le retour d'expérience du
-- hotfix_082, une erreur PERMANENTE est rejouée 10 fois par la file offline
-- puis DROPPÉE en silence : le journal se perdait sans le moindre signal.
--
-- CE QUE FAIT CE HOTFIX :
--   1. Ajoute les 8 colonnes manquantes (les 6 compteurs avant/après, status,
--      cause).
--   2. Élargit le CHECK sur `type` aux 8 valeurs supplémentaires réellement
--      écrites par `_log`, SANS retirer les 9 d'origine — celles-ci sont
--      écrites par les AUTRES chemins (`StockMovement.toMap()` via
--      arrival_service, reception_page, stock_movements_page, app_database) et
--      les retirer casserait ces écritures-là.
--
-- CE QU'IL NE FAIT PAS : `reference` existe déjà et n'est pas touchée. C'est
-- le client qui s'aligne (`'reference_id'` → `'reference'` dans `_log`, plus
-- les TROIS lecteurs Hive qui interrogeaient cette clé). Renommer côté SQL
-- aurait cassé `logs_export_source.dart`, qui lit déjà `m['reference']`.
--
-- NE RESTAURE PAS les mouvements déjà perdus : les journaux purgés le restent.
-- Un stock reconstruit à partir d'eux gardera son écart jusqu'à une
-- réconciliation manuelle. On arrête l'hémorragie, on ne la répare pas
-- rétroactivement.
--
-- ⚠ À APPLIQUER AVANT le déploiement du correctif Dart correspondant. Dans
-- l'autre ordre, les push continuent d'échouer — sans dégât nouveau, mais sans
-- effet non plus.
--
-- Idempotent : ADD COLUMN IF NOT EXISTS + DROP avant ADD CONSTRAINT.
-- ════════════════════════════════════════════════════════════════════════════

-- ─── 1. Les 8 colonnes manquantes ────────────────────────────────────────
-- Les six compteurs avant/après sont le cœur de l'audit de stock :
-- `reconcileShop` et le recalcul de ventes s'appuient sur le dernier
-- `after_available` enregistré. Sans eux, une ligne qui revient du serveur
-- après une purge est un mouvement AMPUTÉ, à partir duquel le stock se
-- reconstruit faux — puis se réécrit.
ALTER TABLE IF EXISTS public.stock_movements
  ADD COLUMN IF NOT EXISTS before_available INTEGER,
  ADD COLUMN IF NOT EXISTS after_available  INTEGER,
  ADD COLUMN IF NOT EXISTS before_blocked   INTEGER,
  ADD COLUMN IF NOT EXISTS after_blocked    INTEGER,
  ADD COLUMN IF NOT EXISTS before_physical  INTEGER,
  ADD COLUMN IF NOT EXISTS after_physical   INTEGER,
  ADD COLUMN IF NOT EXISTS status           TEXT,
  ADD COLUMN IF NOT EXISTS cause            TEXT;

-- ─── 2. CHECK sur `type` — élargi, jamais rétréci ────────────────────────
-- La contrainte d'origine est déclarée EN LIGNE dans le CREATE TABLE du
-- hotfix_010 : elle porte donc un nom auto-généré par Postgres, qu'on ne peut
-- pas deviner de façon fiable. On la retrouve dynamiquement, comme le fait
-- déjà le hotfix_024 pour `shop_memberships.role`.
--
-- ⚠ EXCLUSION OBLIGATOIRE : `stock_movements_reason_required` (hotfix_082)
-- est elle aussi une contrainte CHECK dont la définition MENTIONNE `type`
-- — `CHECK (type <> 'adjustment' OR reason …)`. Sans l'exclure par son nom,
-- la boucle ci-dessous la supprimerait au passage, et le motif obligatoire
-- sur les ajustements sauterait sans que rien ne le signale.
DO $drop_sm_type_chk$
DECLARE v_conname text;
BEGIN
  FOR v_conname IN
    SELECT conname FROM pg_constraint
     WHERE conrelid = 'public.stock_movements'::regclass
       AND contype  = 'c'
       AND pg_get_constraintdef(oid) ILIKE '%type%'
       AND conname  <> 'stock_movements_reason_required'
  LOOP
    EXECUTE format('ALTER TABLE public.stock_movements DROP CONSTRAINT %I',
        v_conname);
  END LOOP;
END $drop_sm_type_chk$;

-- 17 valeurs = les 9 d'origine + les 8 que `_log` écrivait en violation.
--
-- Les 9 d'origine restent INDISPENSABLES : elles proviennent de
-- `StockMovementTypeX.key` et sont écrites par tous les autres chemins
-- (réceptions, arrivages, page mouvements, sync produit). Les retirer pour
-- « faire propre » casserait ces écritures et viderait l'historique existant.
ALTER TABLE IF EXISTS public.stock_movements
  ADD CONSTRAINT stock_movements_type_check
    CHECK (type IN (
      -- ── Les 9 d'origine (hotfix_010), via StockMovementType.key ────────
      'entry',              -- Réception / ajout
      'sale',               -- Vente
      'adjustment',         -- Ajustement manuel
      'incident',           -- Incident (rebut, casse)
      'repair_cost',        -- Coût réparation
      'return_supplier',    -- Retour fournisseur
      'return_client',      -- Retour client
      'transfer',           -- Transfert entre emplacements
      'scrapped',           -- Mise au rebut
      -- ── Les 8 écrites par StockService._log, jusqu'ici rejetées ────────
      'arrival_available',  -- Entrée en stock disponible (arrivage)
      'block_existing',     -- Blocage de stock existant
      'incident_resolved',  -- Résolution d'incident (±)
      'return_client_good', -- Retour client, marchandise saine
      'return_defective',   -- Retour client, marchandise défectueuse
      'arrival_edit',       -- Correction d'un arrivage (delta)
      'arrival_delete',     -- Suppression d'un arrivage
      'recalculate'         -- Recalcul de cohérence (quantité 0)
    ));

-- ────────────────────────────────────────────────────────────────────────
-- Test manuel :
--   1) Vérifier les 20 colonnes :
--      SELECT column_name FROM information_schema.columns
--       WHERE table_name = 'stock_movements' AND table_schema = 'public'
--       ORDER BY ordinal_position;
--      → doit contenir les 12 d'avant + les 8 ajoutées.
--
--   2) Vérifier que les DEUX contraintes coexistent :
--      SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
--       WHERE conrelid = 'public.stock_movements'::regclass AND contype = 'c';
--      → `stock_movements_type_check` ET `stock_movements_reason_required`.
--      Si la seconde a disparu, l'exclusion de la boucle a échoué : ne PAS
--      continuer, la réappliquer depuis hotfix_082.
--
--   3) INSERT type='arrival_available' → OK (rejeté avant ce hotfix).
--      INSERT type='n_importe_quoi'    → ERROR 23514 (le CHECK tient encore).
--      INSERT type='adjustment', reason=NULL → ERROR 23514 (hotfix_082 intact).
--
--   4) Après déploiement du correctif Dart : faire une vente, puis
--      SELECT type, quantity, reference, after_available FROM stock_movements
--       ORDER BY created_at DESC LIMIT 5;
--      → la ligne doit être présente AVEC `reference` = id de commande et
--        `after_available` renseigné. Si `reference` est NULL, le client n'a
--        pas été redéployé.
-- ────────────────────────────────────────────────────────────────────────
