-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_113_delete_plan.sql
--
-- RPC delete_plan(p_id) — super-admin only. Supprime un plan UNIQUEMENT s'il
-- n'est référencé par AUCUN abonnement (jamais utilisé). Sinon → erreur claire
-- invitant à le DÉSACTIVER (is_active=false) pour préserver l'historique et
-- éviter une violation de clé étrangère.
-- Le plan 'trial' (système, lu par le trigger de trial auto) est protégé.
--
-- Idempotent.
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.delete_plan(p_id UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $del$
DECLARE
  v_name  TEXT;
  v_count INT;
  v_email TEXT;
BEGIN
  IF NOT public._is_super_admin() THEN
    RAISE EXCEPTION 'forbidden: super-admin requis' USING ERRCODE = '42501';
  END IF;

  SELECT name INTO v_name FROM public.plans WHERE id = p_id;
  IF v_name IS NULL THEN
    RAISE EXCEPTION 'plan introuvable' USING ERRCODE = 'P0002';
  END IF;

  -- Plan système : ne jamais supprimer (casserait la création d'essais auto).
  IF v_name = 'trial' THEN
    RAISE EXCEPTION 'Le plan d''essai est un plan système et ne peut pas être supprimé.'
      USING ERRCODE = 'P0001';
  END IF;

  -- Refuser si le plan a déjà été utilisé (actif, essai, expiré ou annulé).
  SELECT count(*) INTO v_count
    FROM public.subscriptions WHERE plan_id = p_id;
  IF v_count > 0 THEN
    RAISE EXCEPTION
      'Ce plan a déjà été utilisé par % abonnement(s) — désactivez-le '
      '(décochez « Plan actif ») au lieu de le supprimer.', v_count
      USING ERRCODE = 'P0001';
  END IF;

  DELETE FROM public.plans WHERE id = p_id;

  SELECT email INTO v_email FROM public.profiles WHERE id::text = auth.uid()::text;
  INSERT INTO public.activity_logs
    (actor_id, actor_email, action, target_type, target_id, target_label)
  VALUES
    (auth.uid(), v_email, 'plan_deleted', 'plan', p_id::text, v_name);
END;
$del$;

REVOKE ALL ON FUNCTION public.delete_plan(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_plan(UUID) TO authenticated;

NOTIFY pgrst, 'reload schema';
