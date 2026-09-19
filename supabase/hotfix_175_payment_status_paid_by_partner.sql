-- ═════════════════════════════════════════════════════════════════════════════
-- hotfix_175 — `payment_status` accepte « encaissé par le partenaire ».
--
-- ── Le défaut (ARG-2 de l'audit du parcours de commande) ─────────────────────
-- À la clôture, quand aucun montant encaissé n'est transmis, le code écrit
-- `amount_paid = total` ET `payment_status = 'paid'`. Or ce montant n'est
-- transmis QUE lorsque la BOUTIQUE encaisse : en mode « le partenaire a
-- encaissé », il reste absent.
--
-- Conséquence : la commande est réputée payée alors que l'argent est chez le
-- partenaire. La créance disparaît des créances clients et ne subsiste que
-- dans le livre partenaire — deux écrans qui ne racontent plus la même chose.
--
-- ── Le correctif ────────────────────────────────────────────────────────────
-- Une CINQUIÈME valeur, `paid_by_partner` : le client a payé (donc aucune
-- créance client, et `amount_paid` reste au total — l'argent a bien été
-- encaissé), mais la boutique ne l'a pas encore reçu. Le livre partenaire
-- porte déjà la contrepartie ; ce statut la rend simplement visible sur la
-- commande elle-même.
--
-- `amount_paid` n'est PAS remis à zéro : la somme a été perçue, seul son
-- porteur diffère. La mettre à zéro ferait réapparaître une créance CLIENT
-- qui n'existe pas.
--
-- ── ORDRE D'APPLICATION ─────────────────────────────────────────────────────
-- ⚠ À appliquer AVANT le déploiement du code qui écrit cette valeur. La
-- contrainte actuelle n'admet que quatre valeurs : un upsert portant
-- `paid_by_partner` serait rejeté (23514) et la commande ne remonterait pas.
-- Dans l'autre sens, ce hotfix seul est parfaitement inoffensif — il élargit
-- une contrainte sans rien réécrire.
--
-- Idempotent : DROP IF EXISTS avant ADD.
-- ═════════════════════════════════════════════════════════════════════════════

ALTER TABLE orders DROP CONSTRAINT IF EXISTS orders_payment_status_check;
ALTER TABLE orders ADD CONSTRAINT orders_payment_status_check CHECK (
  payment_status IN ('unpaid', 'partial', 'paid', 'refunded', 'paid_by_partner')
);

COMMENT ON CONSTRAINT orders_payment_status_check ON orders IS
  'unpaid / partial / paid / refunded / paid_by_partner. Cette dernière '
  'valeur (hotfix_175) distingue « le client a payé, mais au partenaire, '
  'qui n''a pas encore versé » de « la boutique a l''argent ». Aucune '
  'créance client dans les deux cas ; la contrepartie partenaire vit dans '
  'le livre partenaire.';

-- Aucun backfill : les commandes existantes gardent leur statut. Celles
-- clôturées « partenaire encaisseur » avant ce correctif restent marquées
-- `paid` — les redresser demanderait de deviner qui a encaissé, ce que la
-- donnée ne dit pas. Seules les clôtures À VENIR sont exactes.

NOTIFY pgrst, 'reload schema';

-- ── Vérification (après application) ────────────────────────────────────────
--   UPDATE orders SET payment_status = 'paid_by_partner'
--   WHERE id = '<une_commande_de_test>';          -- doit passer
--   UPDATE orders SET payment_status = 'n_importe_quoi'
--   WHERE id = '<une_commande_de_test>';          -- doit être rejeté (23514)
