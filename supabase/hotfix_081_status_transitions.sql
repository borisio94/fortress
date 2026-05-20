-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_081_status_transitions.sql
--
-- PR-B des 8 garde-fous stock — GF-4 (verrou de transitions d'état).
--
-- Trigger `BEFORE UPDATE` sur `orders` qui bloque toute transition de
-- statut illégale. Mêmes règles que côté Flutter (`SaleStatusTransitions`
-- dans `sale.dart`) — double verrou client + serveur :
--
--   scheduled  → processing | completed | cancelled | refused      ✓
--   processing → completed  | scheduled | cancelled | refused      ✓
--   completed  → refunded                                            ✓
--   cancelled | refused | refunded → *                              ✗ TERMINAL
--
-- Toute violation lève `transition_interdite` (SQLSTATE P0001, message
-- structuré pour parsing côté client). Les UPDATE qui ne changent PAS le
-- statut (autres colonnes : items, fees, payment_method…) sont autorisés.
--
-- Idempotent : DROP TRIGGER + DROP FUNCTION IF EXISTS avant CREATE.
-- ════════════════════════════════════════════════════════════════════════════

-- ─── 1. Fonction trigger ─────────────────────────────────────────────────
DROP TRIGGER  IF EXISTS trg_orders_status_transitions ON public.orders;
DROP FUNCTION IF EXISTS public.enforce_order_status_transitions();

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

  -- Aucun statut sur OLD (insertion d'un statut depuis NULL — ne devrait pas
  -- arriver sur UPDATE mais filet défensif) → autorisé.
  IF OLD.status IS NULL THEN
    RETURN NEW;
  END IF;

  -- Table des transitions autorisées.
  v_allowed := CASE OLD.status
    WHEN 'scheduled'  THEN NEW.status IN ('processing', 'completed', 'cancelled', 'refused')
    WHEN 'processing' THEN NEW.status IN ('completed', 'scheduled', 'cancelled', 'refused')
    WHEN 'completed'  THEN NEW.status = 'refunded'
    -- États terminaux : aucune transition sortante autorisée.
    WHEN 'cancelled'  THEN false
    WHEN 'refused'    THEN false
    WHEN 'refunded'   THEN false
    ELSE false
  END;

  IF NOT v_allowed THEN
    RAISE EXCEPTION 'transition_interdite'
      USING ERRCODE = 'P0001',
            MESSAGE = format('Transition interdite : %s → %s',
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
    RAISE EXCEPTION 'motif_required'
      USING ERRCODE = 'P0001',
            MESSAGE = 'Motif obligatoire pour annuler une commande.',
            DETAIL  = jsonb_build_object(
                        'order_id', NEW.id::text,
                        'to',       'cancelled')::text;
  END IF;

  RETURN NEW;
END;
$fn$;

-- ─── 2. Trigger BEFORE UPDATE sur orders ─────────────────────────────────
CREATE TRIGGER trg_orders_status_transitions
  BEFORE UPDATE ON public.orders
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_order_status_transitions();

-- ────────────────────────────────────────────────────────────────────────
-- Test manuel :
--   1) Créer un order status='scheduled'.
--   2) UPDATE orders SET status='completed' WHERE id=...; → OK
--   3) UPDATE orders SET status='scheduled' WHERE id=...; → ERROR
--      ('transition_interdite : completed → scheduled')
--   4) UPDATE orders SET status='refunded' WHERE id=...; → OK
--   5) UPDATE orders SET status='cancelled', cancellation_reason='test'
--      WHERE id=... AND status='scheduled'; → OK
--   6) UPDATE orders SET status='cancelled', cancellation_reason=NULL
--      WHERE id=... AND status='scheduled'; → ERROR ('motif_required')
-- ────────────────────────────────────────────────────────────────────────
