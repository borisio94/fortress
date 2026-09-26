-- hotfix_173_order_validation_token.sql
-- ═════════════════════════════════════════════════════════════════════════
-- VALIDER UNE COMMANDE EXIGE DE POSSÉDER LE LIEN.
--
-- `validate_order_by_client` fait passer une commande de « Programmée » à
-- « En cours ». C'est une ÉCRITURE, et elle a une conséquence matérielle :
-- ce statut engage le stock, la marchandise sort des disponibles.
--
-- Elle ne contrôlait pourtant que deux choses : que l'identifiant n'était pas
-- vide, et que la commande existait. Accordée au rôle anonyme, avec des
-- identifiants énumérables côté application, elle laissait n'importe qui
-- faire avancer n'importe quelle commande — et le marchand recevait une
-- notification lui affirmant que son client avait validé.
--
-- LA PREUVE DE POSSESSION EST LE JETON. 128 bits d'entropie valent mieux
-- qu'un numéro de téléphone, d'autant que la page de suivi affichait
-- elle-même ce numéro : la preuve aurait été lisible sur la porte qu'elle
-- gardait. Aucune saisie n'est demandée au client, son parcours est inchangé.
--
-- CONSÉQUENCE ASSUMÉE : les liens déjà envoyés, qui portent l'identifiant,
-- restent LISIBLES (hotfix_172) mais ne permettent plus de VALIDER. Le client
-- concerné passe par la boutique, ou reçoit un nouveau lien. C'est le prix de
-- la fermeture, et il ne porte que sur les commandes encore programmées.
--
-- Le paramètre CHANGE DE NOM (`p_order_id` → `p_tracking_token`) : les deux
-- appelants publics (web/track.html et order_tracking_page.dart) sont mis à
-- jour dans le même commit. La signature restant `(text)`, l'ancienne
-- fonction est remplacée, pas surchargée — on évite la prolifération de
-- surcharges qu'a connue `place_public_order` (cf. hotfix_134).
--
-- Pas de `updated_at` : cette colonne N'EXISTE PAS sur `orders`.
--
-- 100 % idempotent.
-- ═════════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS public.validate_order_by_client(text);

CREATE FUNCTION public.validate_order_by_client(p_tracking_token text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_id     text;
  v_status text;
BEGIN
  IF p_tracking_token IS NULL OR length(trim(p_tracking_token)) = 0 THEN
    RAISE EXCEPTION 'token_required' USING ERRCODE = '22023';
  END IF;

  -- Jeton UNIQUEMENT : un identifiant de commande ne vaut pas preuve.
  -- Le filtre `deleted_at` interdit d'agir sur une commande supprimée.
  SELECT o.id::text, o.status
    INTO v_id, v_status
    FROM orders o
   WHERE o.tracking_token = p_tracking_token
     AND o.deleted_at IS NULL;

  IF v_id IS NULL THEN
    RAISE EXCEPTION 'order_not_found' USING ERRCODE = '42P01';
  END IF;

  -- Déjà validée : réponse idempotente, pas une erreur. Le client qui
  -- retape sur le bouton ne doit pas voir d'échec.
  IF v_status = 'processing' THEN
    RETURN 'already_validated';
  END IF;

  -- Seule transition permise ici. L'automate complet vit dans le déclencheur
  -- `enforce_order_status_transitions` (hotfix_123) ; on refuse en amont
  -- plutôt que de lui laisser lever une exception moins lisible.
  IF v_status IS DISTINCT FROM 'scheduled' THEN
    RETURN 'not_validatable';
  END IF;

  UPDATE orders
     SET status = 'processing'
   WHERE id::text = v_id;

  INSERT INTO activity_logs (id, shop_id, action, target_type, target_id,
                             target_label, details, created_at)
  SELECT gen_random_uuid()::text, o.shop_id, 'order_validated_by_client',
         'sale', o.id::text, o.client_name,
         jsonb_build_object('from', 'scheduled', 'to', 'processing',
                            'via', 'tracking_token'),
         now()
    FROM orders o
   WHERE o.id::text = v_id;

  RETURN 'validated';
END;
$fn$;

REVOKE ALL    ON FUNCTION public.validate_order_by_client(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.validate_order_by_client(text)
  TO anon, authenticated;
