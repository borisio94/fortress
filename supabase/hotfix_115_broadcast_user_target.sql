-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_115_broadcast_user_target.sql
--
-- Ajoute la cible 'user' aux broadcasts → permet de notifier UN utilisateur
-- précis (ex. lors d'un changement majeur opéré par le SA : abonnement
-- mis à jour, boutique réactivée, compte débloqué). target_value = user_id.
-- Le client (broadcasts_provider) affiche le bandeau si target_value = uid.
--
-- send_broadcast (hotfix_090) insère déjà target_type/target_value tels quels ;
-- il suffit d'élargir la contrainte CHECK.
-- Idempotent.
-- ════════════════════════════════════════════════════════════════════════════

ALTER TABLE public.broadcasts
  DROP CONSTRAINT IF EXISTS broadcasts_target_type_check;
ALTER TABLE public.broadcasts
  ADD CONSTRAINT broadcasts_target_type_check
  CHECK (target_type IN ('all', 'plan', 'shop', 'user'));

NOTIFY pgrst, 'reload schema';
