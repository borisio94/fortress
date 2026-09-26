-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_123_completed_to_scheduled.sql
--
-- Autorise la transition `completed → scheduled` côté SERVEUR (trigger
-- `enforce_order_status_transitions`, cf. hotfix_081).
--
-- Contexte : on a ajouté côté Flutter la possibilité de « Repasser une
-- commande complétée en programmée » (correction d'erreur / re-finalisation).
-- Le datasource restitue le stock + remet le paiement à zéro et purge les
-- écritures partenaire de la commande. MAIS le trigger serveur refusait
-- `completed → scheduled` (`transition_interdite`) → l'upsert Supabase était
-- rejeté → au prochain pull, le serveur réimposait `completed` (alors que le
-- stock avait déjà été restitué localement). Ce correctif aligne le serveur
-- sur la règle client (`SaleStatusTransitions` dans sale.dart).
--
-- Nouvelles règles `completed` :
--   completed → refunded   (retour client)                          ✓
--   completed → scheduled  (correction / re-finalisation)           ✓  ← AJOUT
--
-- Le reste des transitions est INCHANGÉ. `CREATE OR REPLACE FUNCTION` suffit :
-- le trigger existant (trg_orders_status_transitions) pointe sur la fonction
-- par son nom et utilisera automatiquement la nouvelle définition.
-- Idempotent : ré-exécutable sans effet de bord.
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.enforce_order_status_transitions()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_allowed boolean := false;
BEGIN
  -- Aucun changement de statut → laisser passer (autres colonnes seulement)
  IF NEW.status = OLD.status THEN
    RETURN NEW;
  END IF;

  -- Aucun statut sur OLD → autorisé (filet défensif).
  IF OLD.status IS NULL THEN
    RETURN NEW;
  END IF;

  -- Table des transitions autorisées.
  v_allowed := CASE OLD.status
    WHEN 'scheduled'  THEN NEW.status IN ('processing', 'completed', 'cancelled', 'refused')
    WHEN 'processing' THEN NEW.status IN ('completed', 'scheduled', 'cancelled', 'refused')
    -- completed : retour client (refunded) OU correction d'erreur (scheduled).
    WHEN 'completed'  THEN NEW.status IN ('refunded', 'scheduled')
    -- États terminaux : aucune transition sortante autorisée.
    WHEN 'cancelled'  THEN false
    WHEN 'refused'    THEN false
    WHEN 'refunded'   THEN false
    ELSE false
  END;

  IF NOT v_allowed THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = format('transition_interdite : %s → %s',
                       OLD.status, NEW.status),
      DETAIL  = jsonb_build_object(
                  'order_id', NEW.id::text,
                  'from',     OLD.status,
                  'to',       NEW.status)::text;
  END IF;

  -- GF-4 bis : motif obligatoire pour passer à `cancelled`.
  IF NEW.status = 'cancelled'
     AND (NEW.cancellation_reason IS NULL
          OR length(trim(NEW.cancellation_reason)) = 0) THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'motif_required : motif obligatoire pour annuler une commande.',
      DETAIL  = jsonb_build_object(
                  'order_id', NEW.id::text,
                  'to',       'cancelled')::text;
  END IF;

  RETURN NEW;
END;
$fn$;

-- ────────────────────────────────────────────────────────────────────────
-- Test manuel :
--   UPDATE orders SET status='scheduled' WHERE id=<une commande completed>;
--   → OK désormais (avant : ERROR transition_interdite : completed → scheduled)
-- ────────────────────────────────────────────────────────────────────────
