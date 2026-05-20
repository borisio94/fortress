-- hotfix_072_partner_ledger_soft_delete.sql
-- ─────────────────────────────────────────────────────────────────────────
-- Suppression DOUCE du livre de comptes partenaires.
--
-- Pourquoi : le modèle offline-first fait du re-push (toute entrée locale
-- absente du serveur est re-poussée pour auto-réparer les pushes échoués).
-- Conséquence : un DELETE serveur est annulé par le re-push d'un autre
-- appareil qui a encore la ligne en local → résurrection (la suppression
-- « ne se reflète pas »). Solution standard : ne jamais DELETE, mais
-- marquer `deleted_at`. La suppression devient une donnée qui converge
-- partout (idempotente au re-push, propagée par realtime UPDATE).
--
-- L'app filtre les lignes `deleted_at IS NOT NULL` (soldes + historique).
-- Idempotent : sûr à ré-exécuter.
-- ─────────────────────────────────────────────────────────────────────────

ALTER TABLE public.partner_ledger_entries
  ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS partner_ledger_not_deleted_idx
  ON public.partner_ledger_entries (shop_id)
  WHERE deleted_at IS NULL;

-- ─────────────────────────────────────────────────────────────────────────
-- REALTIME : hotfix_062 a créé la table mais a OUBLIÉ de la publier en
-- Realtime. Sans ça, l'app écoute les changements mais Postgres ne les
-- diffuse jamais → la synchro entre appareils n'a lieu qu'au prochain
-- pull complet (délai 15 s à plusieurs minutes). On l'ajoute ici, de
-- façon idempotente (ADD TABLE échoue si déjà membre).
-- REPLICA IDENTITY FULL : le payload realtime porte la ligne complète
-- (utile pour lire `deleted_at` / `oldRecord`).
-- ─────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'partner_ledger_entries'
  ) THEN
    ALTER PUBLICATION supabase_realtime
      ADD TABLE public.partner_ledger_entries;
  END IF;
END $$;

ALTER TABLE public.partner_ledger_entries REPLICA IDENTITY FULL;

-- Fin — hotfix_072_partner_ledger_soft_delete.sql
