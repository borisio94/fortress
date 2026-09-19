-- hotfix_126_partner_ledger_rls_fix.sql
-- ═════════════════════════════════════════════════════════════════════════
-- CORRECTIF : erreur de synchro
--   PostgrestException(code: 42501) « new row violates row-level security
--   policy for table "partner_ledger_entries" »
--
-- Cause : la policy d'origine (hotfix_062) n'autorise l'écriture QUE via
-- `_is_shop_member(shop_id)`. Si cette voie échoue (membership pas encore
-- propagée, boutique pas encore synchronisée côté serveur, cast text/uuid,
-- re-flush d'une op offline), l'INSERT/UPSERT est refusé et l'op reste
-- bloquée dans la file (table financière = jamais abandonnée silencieusement).
--
-- Ce hotfix REMPLACE la policy par une version à 3 voies (= hotfix_091,
-- re-livré ici de façon autonome car non appliqué en prod) :
--   1. Voie nominale  : `_is_shop_member(shop_id)` (owner | membre | super-admin).
--   2. Fallback owner : `shops.owner_id = auth.uid()` (bypasse cast/timing).
--   3. Fallback auteur: `created_by_user_id = auth.uid()` — l'auteur peut
--      TOUJOURS écrire SA propre ligne (débloque le retry de la file).
--
-- 100 % idempotent : DROP POLICY IF EXISTS + CREATE POLICY. Sûr à rejouer
-- même si hotfix_091 a déjà été appliqué.
-- ═════════════════════════════════════════════════════════════════════════

-- Garde-fou : la voie nominale dépend du helper de hotfix_041.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc
     WHERE proname      = '_is_shop_member'
       AND pronamespace = 'public'::regnamespace
  ) THEN
    RAISE EXCEPTION
      'Fonction public._is_shop_member() manquante — appliquer d''abord '
      'hotfix_041_rls_critical_tables.sql.';
  END IF;
END $$;

ALTER TABLE public.partner_ledger_entries ENABLE ROW LEVEL SECURITY;

-- Remplacement atomique : on garde le MÊME nom de policy pour éviter deux
-- policies cumulatives.
DROP POLICY IF EXISTS partner_ledger_members_or_owner
  ON public.partner_ledger_entries;

CREATE POLICY partner_ledger_members_or_owner
  ON public.partner_ledger_entries
  FOR ALL TO authenticated
  USING (
    public._is_shop_member(shop_id)
    OR EXISTS (
      SELECT 1 FROM public.shops s
       WHERE s.id::text       = partner_ledger_entries.shop_id
         AND s.owner_id::text = auth.uid()::text
    )
    OR partner_ledger_entries.created_by_user_id::text = auth.uid()::text
  )
  WITH CHECK (
    public._is_shop_member(shop_id)
    OR EXISTS (
      SELECT 1 FROM public.shops s
       WHERE s.id::text       = partner_ledger_entries.shop_id
         AND s.owner_id::text = auth.uid()::text
    )
    OR partner_ledger_entries.created_by_user_id::text = auth.uid()::text
  );

-- ── Vérification (à exécuter après application) ───────────────────────────
--   SELECT polname, polcmd,
--          pg_get_expr(polqual,      polrelid) AS using_expr,
--          pg_get_expr(polwithcheck, polrelid) AS check_expr
--     FROM pg_policy
--    WHERE polrelid = 'public.partner_ledger_entries'::regclass;
--
-- ── Diagnostic : lignes éventuellement « orphelines » (shop introuvable ou
--    non possédé) qui resteraient bloquées même après ce correctif — typique
--    d'une op de file résiduelle d'un AUTRE compte (queue Hive partagée par
--    appareil). À inspecter avec une session authentifiée de l'utilisateur :
--   SELECT ple.id, ple.shop_id, ple.created_by_user_id
--     FROM public.partner_ledger_entries ple
--     LEFT JOIN public.shops s ON s.id::text = ple.shop_id
--    WHERE s.id IS NULL;
--
-- Fin — hotfix_126_partner_ledger_rls_fix.sql
