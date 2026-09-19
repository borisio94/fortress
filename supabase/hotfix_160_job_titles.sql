-- hotfix_160_job_titles.sql
-- ═════════════════════════════════════════════════════════════════════════
-- LES POSTES DE L'ÉTABLISSEMENT — une liste que le restaurant gère lui-même.
--
-- Jusqu'ici la liste des fonctions proposées à la création d'un compte venait
-- de trois sources bancales :
--   * une constante figée dans le code (`StaffMember.suggestedRoles`) —
--     ni supprimable ni modifiable ;
--   * des ajouts rangés dans les préférences de l'APPAREIL — invisibles sur
--     la tablette de la caisse ;
--   * les libellés déjà portés par les comptes — qui ne remontaient qu'après
--     avoir été attribués à quelqu'un.
--
-- Aucun établissement n'a exactement les postes d'un autre : celui-ci a un
-- chawarmier et un glacier, celui-là un pâtissier et pas de barman. La liste
-- devient donc une donnée de la boutique, ajoutable, renommable, supprimable,
-- et la même sur tous les appareils.
--
-- MÊME FORME QUE `brands` / `units` — (shop_id, name) en clé primaire, pas
-- d'id technique. Deux raisons : le libellé EST l'identité (deux postes de
-- même nom n'ont aucun sens), et l'upsert offline de deux appareils qui
-- créent « Pâtissier » en même temps converge au lieu de créer un doublon.
--
-- Ce que cette table N'EST PAS : la fonction d'une personne. Celle-ci reste
-- sur `shop_memberships.job_title` (hotfix_159), recopiée sur la fiche
-- Personnel. Supprimer un poste de la liste ne débaptise personne — c'est
-- l'application qui refuse la suppression tant que quelqu'un le porte.
--
-- 100 % idempotent (ré-exécutable sans effet de bord).
-- ═════════════════════════════════════════════════════════════════════════

-- Garde-fou : la RLS dépend du helper de hotfix_041.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc
     WHERE proname = '_is_shop_member'
       AND pronamespace = 'public'::regnamespace
  ) THEN
    RAISE EXCEPTION
      'public._is_shop_member(text) manquant — appliquer hotfix_041 d''abord.';
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.job_titles (
  shop_id    TEXT NOT NULL REFERENCES public.shops(id) ON DELETE CASCADE,
  name       TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now(),
  PRIMARY KEY (shop_id, name)
);

COMMENT ON TABLE public.job_titles IS
  'Postes proposés à la création d''un compte de la boutique (Serveur, '
  'Cuisinier, Livreur…) — hotfix_160. La fonction RÉELLEMENT portée par une '
  'personne vit sur shop_memberships.job_title.';

-- La liste est toujours lue boutique par boutique.
CREATE INDEX IF NOT EXISTS job_titles_shop_idx ON public.job_titles(shop_id);

-- ── RLS : membres / owner / super-admin (lecture + écriture) ──────────────
ALTER TABLE public.job_titles ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS job_titles_members ON public.job_titles;
CREATE POLICY job_titles_members ON public.job_titles
  FOR ALL TO authenticated
  USING (public._is_shop_member(shop_id))
  WITH CHECK (public._is_shop_member(shop_id));

-- ── Realtime : la liste change sur un appareil, elle change sur les autres ─
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
     WHERE pubname = 'supabase_realtime'
       AND schemaname = 'public'
       AND tablename  = 'job_titles'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.job_titles;
  END IF;
END $$;

-- ── Vérification ─────────────────────────────────────────────────────────
--
--   SELECT tablename, rowsecurity FROM pg_tables
--    WHERE schemaname='public' AND tablename='job_titles';
--
--   SELECT policyname FROM pg_policies
--    WHERE schemaname='public' AND tablename='job_titles';
--
--   SELECT tablename FROM pg_publication_tables
--    WHERE pubname='supabase_realtime' AND tablename='job_titles';
--
--   -- Postes d'une boutique, et qui les porte :
--   SELECT j.name, count(m.user_id) AS titulaires
--     FROM public.job_titles j
--     LEFT JOIN public.shop_memberships m
--            ON m.shop_id = j.shop_id AND m.job_title = j.name
--    WHERE j.shop_id = '<shop>'
--    GROUP BY j.name ORDER BY j.name;
--
-- Fin — hotfix_160_job_titles.sql
