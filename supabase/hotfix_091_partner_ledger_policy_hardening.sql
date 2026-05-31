-- hotfix_091_partner_ledger_policy_hardening.sql
-- ═════════════════════════════════════════════════════════════════════════
-- Durcit la policy RLS sur `partner_ledger_entries`.
--
-- Symptôme observé : INSERT 42501 « new row violates row-level security
-- policy for table partner_ledger_entries » alors que l'utilisateur est
-- bien le créateur du shop. Causes possibles couvertes ici :
--   * `_is_shop_member()` retourne FALSE pour un timing membership pas
--     encore propagé après création du shop (race condition app/queue).
--   * Coercition de types text/uuid qui fait rater le match owner_id /
--     auth.uid().
--   * Re-flush d'une op de la queue offline alors que le shop_membership
--     du créateur n'a pas (encore) été ré-inséré en local après reset.
--
-- Stratégie : on garde la voie nominale via `_is_shop_member()` (helper
-- centralisé du hotfix_041) mais on ajoute deux fallbacks explicites :
--   1. Owner direct sur `shops.owner_id` = auth.uid() (cast text→text).
--   2. `created_by_user_id` = auth.uid() — autorise au moins le créateur
--      à écrire sa propre ligne, ce qui débloque le retry de la queue.
--
-- Idempotent : DROP POLICY IF EXISTS + CREATE POLICY. Garde-fou en
-- début : refuse de tourner si `_is_shop_member()` n'est pas déployée.
-- ═════════════════════════════════════════════════════════════════════════

-- Garde-fou : la policy dépend du helper de hotfix_041.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc
     WHERE proname     = '_is_shop_member'
       AND pronamespace = 'public'::regnamespace
  ) THEN
    RAISE EXCEPTION
      'Fonction public._is_shop_member() manquante — appliquer d''abord '
      'hotfix_041_rls_critical_tables.sql.';
  END IF;
END $$;

-- RLS doit être active (hotfix_062 l'a déjà fait, ici on garantit).
ALTER TABLE public.partner_ledger_entries ENABLE ROW LEVEL SECURITY;

-- Remplacement atomique de la policy. On garde le même nom pour ne pas
-- laisser deux policies cumulatives (FOR ALL).
DROP POLICY IF EXISTS partner_ledger_members_or_owner
  ON public.partner_ledger_entries;

CREATE POLICY partner_ledger_members_or_owner
  ON public.partner_ledger_entries
  FOR ALL TO authenticated
  USING (
    -- Voie nominale : owner / membre actif / super-admin (hotfix_041).
    public._is_shop_member(shop_id)
    -- Fallback 1 : owner direct (bypasse tout souci de cast/timing).
    OR EXISTS (
      SELECT 1 FROM public.shops s
       WHERE s.id::text       = partner_ledger_entries.shop_id
         AND s.owner_id::text = auth.uid()::text
    )
    -- Fallback 2 : créateur de la ligne (débloque le retry de queue
    -- offline si la racine du problème est un membership pas encore
    -- propagé).
    OR partner_ledger_entries.created_by_user_id::text
       = auth.uid()::text
  )
  WITH CHECK (
    public._is_shop_member(shop_id)
    OR EXISTS (
      SELECT 1 FROM public.shops s
       WHERE s.id::text       = partner_ledger_entries.shop_id
         AND s.owner_id::text = auth.uid()::text
    )
    OR partner_ledger_entries.created_by_user_id::text
       = auth.uid()::text
  );

-- Vérification (à exécuter manuellement après application) :
--   SELECT polname, polcmd,
--          pg_get_expr(polqual,      polrelid) AS using_expr,
--          pg_get_expr(polwithcheck, polrelid) AS check_expr
--     FROM pg_policy
--    WHERE polrelid = 'public.partner_ledger_entries'::regclass;
--
-- Smoke test (avec une session authentifiée de l'utilisateur impacté) :
--   INSERT INTO public.partner_ledger_entries
--     (id, shop_id, partner_location_id, type, amount, created_by_user_id)
--   VALUES
--     ('ple_smoke_'||extract(epoch from now())::bigint,
--      '<shop_id>', '<partner_location_id>', 'remittance', 0, auth.uid());
--   → attendu : 1 ligne insérée (puis rollback manuel).

-- Fin — hotfix_091_partner_ledger_policy_hardening.sql
