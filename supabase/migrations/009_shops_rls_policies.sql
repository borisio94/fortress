-- =============================================================================
-- 009 — RLS policies pour `shops` et `shop_memberships`
--
-- Corrige :
--   1. "Erreur 42501" — INSERT refusé sur shops (manque de policy).
--   2. "Erreur 42883: operator does not exist: uuid = text" — schéma mixte
--      (shops.id en TEXT, auth.uid() en UUID). On caste tout en ::text.
--   3. "Erreur 500: infinite recursion detected" — la policy SELECT de shops
--      interroge shop_memberships et inversement → récursion mutuelle.
--      On casse la boucle avec deux fonctions SECURITY DEFINER qui bypassent
--      RLS pour calculer les listes de shop_ids accessibles à l'utilisateur.
--
-- Idempotente : peut être ré-exécutée sans rien casser.
-- =============================================================================

-- ─── Fonctions helpers (bypass RLS, brisent la récursion) ───────────────────
-- SECURITY DEFINER = exécutée avec les droits du créateur (postgres) au lieu
-- de ceux de l'appelant → contourne RLS sur les tables interrogées.
-- STABLE = même résultat dans la même transaction → cacheable par le planner.

CREATE OR REPLACE FUNCTION public.user_shop_ids()
RETURNS SETOF text
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT (shop_id)::text
  FROM public.shop_memberships
  WHERE (user_id)::text = (auth.uid())::text;
$$;

CREATE OR REPLACE FUNCTION public.user_owned_shop_ids()
RETURNS SETOF text
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT (id)::text
  FROM public.shops
  WHERE (owner_id)::text = (auth.uid())::text;
$$;

-- Permettre l'appel par les rôles authentifiés.
GRANT EXECUTE ON FUNCTION public.user_shop_ids()       TO authenticated;
GRANT EXECUTE ON FUNCTION public.user_owned_shop_ids() TO authenticated;

-- ─── Table shops ────────────────────────────────────────────────────────────

ALTER TABLE public.shops ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS shops_insert_owner            ON public.shops;
DROP POLICY IF EXISTS shops_select_owner_or_member  ON public.shops;
DROP POLICY IF EXISTS shops_update_owner            ON public.shops;
DROP POLICY IF EXISTS shops_delete_owner            ON public.shops;

-- INSERT : créer une boutique dont on est le owner.
CREATE POLICY shops_insert_owner
  ON public.shops
  FOR INSERT
  TO authenticated
  WITH CHECK ((auth.uid())::text = (owner_id)::text);

-- SELECT : owner OU membre. Pas de sous-requête sur shop_memberships ici —
-- on délègue à `user_shop_ids()` qui bypass RLS et brise la récursion.
CREATE POLICY shops_select_owner_or_member
  ON public.shops
  FOR SELECT
  TO authenticated
  USING (
    (auth.uid())::text = (owner_id)::text
    OR (id)::text IN (SELECT public.user_shop_ids())
  );

-- UPDATE : owner uniquement.
CREATE POLICY shops_update_owner
  ON public.shops
  FOR UPDATE
  TO authenticated
  USING       ((auth.uid())::text = (owner_id)::text)
  WITH CHECK  ((auth.uid())::text = (owner_id)::text);

-- DELETE : owner uniquement.
CREATE POLICY shops_delete_owner
  ON public.shops
  FOR DELETE
  TO authenticated
  USING ((auth.uid())::text = (owner_id)::text);

-- ─── Table shop_memberships ─────────────────────────────────────────────────

ALTER TABLE public.shop_memberships ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS shop_memberships_insert_owner  ON public.shop_memberships;
DROP POLICY IF EXISTS shop_memberships_select        ON public.shop_memberships;
DROP POLICY IF EXISTS shop_memberships_update_owner  ON public.shop_memberships;
DROP POLICY IF EXISTS shop_memberships_delete_owner  ON public.shop_memberships;

-- INSERT : un owner peut ajouter des memberships sur SES boutiques.
-- Délègue à `user_owned_shop_ids()` pour éviter la récursion vers `shops`.
CREATE POLICY shop_memberships_insert_owner
  ON public.shop_memberships
  FOR INSERT
  TO authenticated
  WITH CHECK ((shop_id)::text IN (SELECT public.user_owned_shop_ids()));

-- SELECT : le membre lui-même OU l'owner de la boutique.
CREATE POLICY shop_memberships_select
  ON public.shop_memberships
  FOR SELECT
  TO authenticated
  USING (
    (user_id)::text = (auth.uid())::text
    OR (shop_id)::text IN (SELECT public.user_owned_shop_ids())
  );

-- UPDATE / DELETE : owner uniquement.
CREATE POLICY shop_memberships_update_owner
  ON public.shop_memberships
  FOR UPDATE
  TO authenticated
  USING      ((shop_id)::text IN (SELECT public.user_owned_shop_ids()))
  WITH CHECK ((shop_id)::text IN (SELECT public.user_owned_shop_ids()));

CREATE POLICY shop_memberships_delete_owner
  ON public.shop_memberships
  FOR DELETE
  TO authenticated
  USING ((shop_id)::text IN (SELECT public.user_owned_shop_ids()));
