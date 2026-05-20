-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_056_ticket_escalation.sql
--
-- RPC pour escalader un ticket dans la hiérarchie : admin → owner →
-- super_admin. Atomique (transaction) : insère une ligne dans
-- `shop_ticket_escalations` ET met à jour `shop_tickets.current_level`.
--
-- Garde-fous :
--   * `admin → owner`         : tout admin/owner de la shop peut le faire.
--   * `owner → super_admin`   : seul le owner de la shop peut le faire.
--   * `super_admin → ?`       : refusé (pas d'échelon plus haut).
--   * Saut de niveau interdit (admin → super_admin direct).
--
-- Idempotent (CREATE OR REPLACE).
-- Pré-requis : hotfix_055 appliqué (tables tickets en place).
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.escalate_ticket(
  p_ticket_id text,
  p_reason    text DEFAULT NULL
) RETURNS text  -- nouveau current_level
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_caller     uuid := auth.uid();
  v_caller_txt text := v_caller::text;
  v_ticket     shop_tickets%ROWTYPE;
  v_from       text;
  v_to         text;
  v_membership_role text;
  v_is_owner   boolean := false;
  v_escal_id   text;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_ticket FROM shop_tickets WHERE id = p_ticket_id;
  IF v_ticket.id IS NULL THEN
    RAISE EXCEPTION 'ticket_not_found' USING ERRCODE = '42P01';
  END IF;
  IF v_ticket.status <> 'open' THEN
    RAISE EXCEPTION 'ticket_not_open' USING ERRCODE = '22023';
  END IF;

  v_from := v_ticket.current_level;
  IF v_from = 'admin' THEN
    v_to := 'owner';
  ELSIF v_from = 'owner' THEN
    v_to := 'super_admin';
  ELSE
    -- super_admin ou autre : pas d'escalade possible.
    RAISE EXCEPTION 'no_higher_level' USING ERRCODE = '22023';
  END IF;

  -- Vérifier que le caller a le droit d'effectuer ce saut.
  -- (admin → owner) : être admin ou owner de la shop.
  -- (owner → super_admin) : être owner uniquement.
  SELECT role INTO v_membership_role
    FROM shop_memberships
   WHERE shop_id::text = v_ticket.shop_id
     AND user_id::text = v_caller_txt
   LIMIT 1;

  -- Owner direct via shops.owner_id (cas où la membership n'existerait pas).
  SELECT EXISTS(
    SELECT 1 FROM shops
     WHERE id = v_ticket.shop_id
       AND owner_id::text = v_caller_txt
  ) INTO v_is_owner;

  IF v_to = 'owner' THEN
    -- admin OU owner suffit
    IF NOT (v_membership_role IN ('admin','owner') OR v_is_owner) THEN
      RAISE EXCEPTION 'escalate_to_owner_forbidden' USING ERRCODE = '42501';
    END IF;
  ELSIF v_to = 'super_admin' THEN
    -- owner uniquement
    IF NOT (v_membership_role = 'owner' OR v_is_owner) THEN
      RAISE EXCEPTION 'escalate_to_super_admin_forbidden' USING ERRCODE = '42501';
    END IF;
  END IF;

  v_escal_id := 'esc_' || extract(epoch from now())::bigint::text || '_'
                || substring(gen_random_uuid()::text, 1, 6);

  INSERT INTO shop_ticket_escalations
    (id, ticket_id, from_level, to_level, reason, by_user, created_at)
  VALUES (v_escal_id, p_ticket_id, v_from, v_to,
          NULLIF(trim(coalesce(p_reason, '')), ''),
          v_caller_txt, now());

  UPDATE shop_tickets
     SET current_level = v_to,
         updated_at    = now()
   WHERE id = p_ticket_id;

  RETURN v_to;
END;
$fn$;

REVOKE ALL ON FUNCTION public.escalate_ticket(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.escalate_ticket(text, text) TO authenticated;

-- ════════════════════════════════════════════════════════════════════════════
-- Vérification : la fonction doit exister.
--   SELECT proname FROM pg_proc WHERE proname = 'escalate_ticket';
-- ════════════════════════════════════════════════════════════════════════════
