/// PAYER EN DEUX FOIS — ET SEULEMENT EN DEUX FOIS, PAS À MOITIÉ.
///
/// La feuille d'encaissement savait empiler plusieurs règlements. Cette
/// mécanique a été RETIRÉE le 2026-08-03, et sa doc dit pourquoi : elle
/// servait aussi l'acompte, elle imposait une saisie chiffrée à chaque
/// encaissement, et *« le bouton pouvait valider une addition partiellement
/// payée, laissant une créance sans que personne ne l'ait voulu »*.
///
/// LE RÈGLEMENT MIXTE REVIENT, L'ACOMPTE NON. Un client qui paie 4 000 en
/// espèces et le reste en MTN est le cas courant ici ; un client qui paie la
/// moitié et s'en va est une créance, et l'addition n'est pas l'écran où l'on
/// décide d'en ouvrir une.
///
/// La différence tient en une règle : **on ne valide que si le total est
/// couvert**. C'est ce fichier, et rien d'autre. L'arithmétique — ce qui est
/// imputé, ce qui est rendu, ce qui déborde — appartient à `PaymentSplit`, qui
/// la fait déjà et la fait bien.
///
/// LE CAS COURANT NE COÛTE RIEN. Un seul mode choisi, aucun montant saisi :
/// la feuille se comporte exactement comme avant, un tap et c'est réglé. Le
/// partage est une porte qu'on pousse, pas un passage obligé.
library;

import '../../../core/services/payment_service.dart';
import 'entities/payment.dart';

/// Ce que la feuille doit afficher et autoriser, pour une saisie donnée.
typedef MixedPaymentState = ({
  /// Le calcul complet, tel que `PaymentSplit` le rend.
  PaymentSplit split,

  /// Reste dû après imputation. Zéro = couvert.
  int remaining,

  /// Rendu monnaie, en espèces uniquement.
  int change,

  /// Le bouton d'encaissement est-il actif ?
  bool canValidate,

  /// Pourquoi il ne l'est pas. `null` quand il l'est.
  ///
  /// Un bouton grisé sans raison affichée se lit comme une panne — c'est la
  /// règle déjà tenue par la feuille « Type de commande ».
  String? blocker,
});

/// Évalue une saisie de règlement.
///
/// [due] est le montant de l'addition. [entries] sont les règlements annoncés,
/// dans l'ordre de saisie — chacun absorbe ce qui reste dû, au plus.
MixedPaymentState mixedPaymentState({
  required int due,
  required List<PaymentEntry> entries,
}) {
  final split = PaymentSplit.compute(due, entries);
  final remaining = split.remaining;

  String? blocker;
  if (entries.isEmpty) {
    blocker = 'Ajoute au moins un règlement.';
  } else if (remaining > 0) {
    // LE GARDE DE CE FICHIER. Il ne dit pas « saisis plus » : il dit combien il
    // manque, parce que c'est le chiffre que le caissier doit réclamer au
    // client, et qu'il ne doit pas avoir à le soustraire de tête.
    blocker = 'Il manque $remaining pour couvrir l\'addition.';
  } else if (split.hasOverpay) {
    // Un transfert MTN de 6 000 sur une addition de 5 000 ne se rend pas : la
    // somme est partie, et l'encaisser laisserait 1 000 de trop dans les
    // comptes du jour. C'est une erreur de saisie, elle se corrige avant de
    // valider — pas après.
    blocker = 'Un règlement non-espèces dépasse le reste dû : corrige le '
        'montant, on ne rend pas la monnaie d\'un transfert.';
  }

  return (
    split: split,
    remaining: remaining,
    change: split.change,
    canValidate: blocker == null,
    blocker: blocker,
  );
}

/// La saisie par défaut : un seul mode, le montant exact.
///
/// C'est le chemin d'avant, conservé tel quel — un tap sur le mode, un tap sur
/// « Encaisser ». `received == due` donc `change == 0` : rien à rendre, rien à
/// annoncer.
List<PaymentEntry> singleEntry({
  required int due,
  required PaymentMode mode,
  String? reference,
}) =>
    [PaymentEntry(mode: mode, received: due, reference: reference)];
