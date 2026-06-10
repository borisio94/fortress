-- ════════════════════════════════════════════════════════════════════════
-- hotfix_117 : autoriser la suppression des commandes ANNULÉES
-- ════════════════════════════════════════════════════════════════════════
-- La spec initiale (hotfix_084) autorisait la suppression pour
-- {scheduled, processing, refused} et refusait `cancelled`. Demande produit :
-- pouvoir aussi supprimer une commande annulée (et programmée — déjà permise).
--
-- On ajoute donc `cancelled` à la liste des statuts éligibles. Le garde-fou
-- paiement (amount_paid = 0) reste inchangé : une commande annulée mais
-- encaissée (acompte) ne peut toujours pas être supprimée sans remboursement.
--
-- CREATE OR REPLACE de delete_sale (corps identique à hotfix_084, seule la
-- liste des statuts change). Idempotent. À appliquer dans le SQL editor.
-- Doit rester aligné avec DeleteSaleUseCase.allowedStatuses côté Flutter.
-- ════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.delete_sale(
  p_sale_id text,
  p_user_id uuid,
  p_reason  text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_status      text;
  v_amount_paid double precision;
  v_already     timestamptz;
  v_shop_id     text;
  v_client_name text;
  v_reason      text := COALESCE(trim(p_reason), '');
BEGIN
  -- ── 1. Validation du motif (min 10 caractères, cohérent dialog Flutter).
  IF length(v_reason) < 10 THEN
    RAISE EXCEPTION 'motif_required'
      USING ERRCODE = 'P0001',
            MESSAGE = 'Motif obligatoire (10 caractères minimum).',
            DETAIL  = jsonb_build_object('code', 'motif_required')::text;
  END IF;

  -- ── 2. Verrouillage + lecture de l'état actuel.
  SELECT status, COALESCE(amount_paid, 0), deleted_at, shop_id, client_name
    INTO v_status, v_amount_paid, v_already, v_shop_id, v_client_name
    FROM public.orders
   WHERE id = p_sale_id
     FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'sale_not_found'
      USING ERRCODE = 'P0002',
            MESSAGE = 'Commande introuvable.',
            DETAIL  = jsonb_build_object('code', 'sale_not_found',
                                         'sale_id', p_sale_id)::text;
  END IF;

  -- ── 3. Idempotence : déjà supprimée → no-op.
  IF v_already IS NOT NULL THEN
    RETURN jsonb_build_object(
      'sale_id',      p_sale_id,
      'deleted_at',   v_already,
      'already',      true
    );
  END IF;

  -- ── 4. Garde-fou statut. Autorisé : scheduled + processing + refused +
  --       cancelled (hotfix_117). Tout autre statut (completed, refunded)
  --       refuse la suppression — passer par les flows métier dédiés.
  IF v_status NOT IN ('scheduled', 'processing', 'refused', 'cancelled') THEN
    RAISE EXCEPTION 'suppression_statut_invalide'
      USING ERRCODE = 'P0001',
            MESSAGE = format(
              'Suppression refusée : statut « %s » non éligible.', v_status),
            DETAIL  = jsonb_build_object(
              'code',    'suppression_statut_invalide',
              'status',  v_status,
              'allowed', jsonb_build_array(
                           'scheduled','processing','refused','cancelled')
            )::text;
  END IF;

  -- ── 5. Garde-fou paiement. Une commande même partiellement encaissée ne
  --       peut pas être supprimée : il faut d'abord rembourser le client.
  IF v_amount_paid > 0 THEN
    RAISE EXCEPTION 'suppression_commande_payee'
      USING ERRCODE = 'P0001',
            MESSAGE = format(
              'Suppression refusée : commande encaissée à hauteur de %s.',
              v_amount_paid),
            DETAIL  = jsonb_build_object(
              'code',        'suppression_commande_payee',
              'amount_paid', v_amount_paid
            )::text;
  END IF;

  -- ── 6. Soft-delete. UPDATE atomique avec l'auteur et le motif.
  UPDATE public.orders
     SET deleted_at    = NOW(),
         deleted_by    = p_user_id,
         delete_reason = v_reason
   WHERE id = p_sale_id;

  -- ── 7. Trace dans activity_logs.
  INSERT INTO public.activity_logs (
    actor_id, actor_email,
    action, target_type, target_id, target_label,
    shop_id, details, created_at
  )
  SELECT
    auth.uid(),
    (SELECT email FROM auth.users WHERE id = auth.uid()),
    'sale_deleted',
    'sale',
    p_sale_id,
    v_client_name,
    v_shop_id::uuid,
    jsonb_build_object(
      'reason',      v_reason,
      'status_before', v_status,
      'amount_paid', v_amount_paid,
      'deleted_by',  p_user_id
    ),
    NOW();

  RETURN jsonb_build_object(
    'sale_id',    p_sale_id,
    'deleted_at', NOW(),
    'already',    false
  );
END;
$fn$;

ALTER FUNCTION public.delete_sale(text, uuid, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.delete_sale(text, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_sale(text, uuid, text)
  TO authenticated;
