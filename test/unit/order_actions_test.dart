import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/caisse/domain/entities/sale.dart';
import 'package:fortress/features/restaurant/domain/order_actions.dart';

/// Un cas s'écrit en UNE ligne : tout est nommé et tout a un défaut « permissif
/// mais banal » — commande de salle programmée, opérateur qui peut tout faire,
/// rien d'encaissé. Chaque test ne dit donc que ce qu'il change.
List<OrderAction> actions({
  SaleStatus status = SaleStatus.scheduled,
  bool isApprovalSale = false,
  double amountDue = 0,
  double amountPaid = 0,
  String? source,
  bool canCancel = true,
  bool canEdit = true,
  bool canDelete = true,
  bool isResto = true,
  bool canConfirmClient = false,
}) =>
    orderActionsFor(
      status: status,
      isApprovalSale: isApprovalSale,
      amountDue: amountDue,
      amountPaid: amountPaid,
      source: source,
      canCancel: canCancel,
      canEdit: canEdit,
      canDelete: canDelete,
      isResto: isResto,
      canConfirmClient: canConfirmClient,
    );

void main() {
  group('Les douze conditions, une par une', () {
    test('1+2 · la tournée remplace les transitions génériques', () {
      final a = actions(isApprovalSale: true);
      expect(a, containsAll([
        OrderAction.closeApprovalRound,
        OrderAction.cancelApprovalRound,
      ]));
      // Et elle les REMPLACE : pas de transition générique en même temps.
      expect(a, isNot(contains(OrderAction.advanceStatus)));
      expect(a, isNot(contains(OrderAction.cancelOrRefuse)));
      // Seulement sur une commande ouverte.
      expect(actions(isApprovalSale: true, status: SaleStatus.completed),
          isNot(contains(OrderAction.closeApprovalRound)));
    });

    test('3 · avancer : bouton sur programmée et en cours, jamais ailleurs', () {
      expect(actions(status: SaleStatus.scheduled),
          contains(OrderAction.advanceStatus));
      expect(actions(status: SaleStatus.processing),
          contains(OrderAction.advanceStatus));
      // À échéance, la pastille remplace le bouton : ce n'est pas une action.
      expect(actions(canConfirmClient: true),
          isNot(contains(OrderAction.advanceStatus)));
      for (final s in [
        SaleStatus.completed,
        SaleStatus.cancelled,
        SaleStatus.refused,
        SaleStatus.refunded,
      ]) {
        expect(actions(status: s), isNot(contains(OrderAction.advanceStatus)),
            reason: '$s ne porte pas de bouton d\'avancement');
      }
    });

    test('4 · annuler ou refuser : ouverte, permis, hors échéance', () {
      expect(actions(), contains(OrderAction.cancelOrRefuse));
      expect(actions(canCancel: false),
          isNot(contains(OrderAction.cancelOrRefuse)));
      expect(actions(status: SaleStatus.completed),
          isNot(contains(OrderAction.cancelOrRefuse)));
      expect(actions(canConfirmClient: true),
          isNot(contains(OrderAction.cancelOrRefuse)));
    });

    test('5 · repasser en programmée : encaissée ET permis', () {
      expect(actions(status: SaleStatus.completed),
          contains(OrderAction.reopenPaidSale));
      expect(actions(status: SaleStatus.completed, canCancel: false),
          isNot(contains(OrderAction.reopenPaidSale)));
      expect(actions(), isNot(contains(OrderAction.reopenPaidSale)));
    });

    test('6+7 · les deux factures n\'existent que sur une encaissée', () {
      final a = actions(status: SaleStatus.completed);
      expect(a, containsAll([
        OrderAction.invoicePdf,
        OrderAction.invoiceWhatsApp,
      ]));
      expect(actions(), isNot(contains(OrderAction.invoicePdf)));
      expect(actions(), isNot(contains(OrderAction.invoiceWhatsApp)));
    });

    test('8 · acompte : un reste dû, sur une commande encore vivante', () {
      expect(actions(status: SaleStatus.completed, amountDue: 1500),
          contains(OrderAction.collectBalance));
      // Une commande ouverte avec un reste dû l'ouvre AUSSI — c'est la règle
      // de HEAD, volontairement conservée (cf. le commentaire de la règle).
      expect(actions(amountDue: 1500),
          contains(OrderAction.collectBalance));
      // Soldée : rien à encaisser.
      expect(actions(status: SaleStatus.completed, amountDue: 0),
          isNot(contains(OrderAction.collectBalance)));
      // Morte : plus rien ne rentre.
      for (final st in [
        SaleStatus.cancelled,
        SaleStatus.refused,
        SaleStatus.refunded,
      ]) {
        expect(actions(status: st, amountDue: 1500),
            isNot(contains(OrderAction.collectBalance)),
            reason: 'rien à encaisser sur une $st');
      }
    });

    test('9 · relancer : ouverte et non issue du web', () {
      expect(actions(), contains(OrderAction.relaunchClient));
      expect(actions(source: 'web'),
          isNot(contains(OrderAction.relaunchClient)));
      expect(actions(status: SaleStatus.completed),
          isNot(contains(OrderAction.relaunchClient)));
    });

    test('10 · modifier les frais : JAMAIS en restauration', () {
      expect(actions(isResto: true), isNot(contains(OrderAction.editFees)));
      // Hors restauration, la condition d'origine reprend ses droits.
      expect(actions(isResto: false), contains(OrderAction.editFees));
      expect(actions(isResto: false, canEdit: false),
          isNot(contains(OrderAction.editFees)));
      for (final s in [
        SaleStatus.cancelled,
        SaleStatus.refused,
        SaleStatus.refunded,
      ]) {
        expect(actions(isResto: false, status: s),
            isNot(contains(OrderAction.editFees)),
            reason: 'des frais sur une $s n\'ont pas d\'objet');
      }
    });

    test('11 · modifier la commande : e-commerce, permis et pas encore '
        'encaissée', () {
      expect(actions(isResto: false), contains(OrderAction.editOrder));
      expect(actions(isResto: false, canEdit: false),
          isNot(contains(OrderAction.editOrder)));
      // Les articles sont figés une fois la commande complétée.
      expect(actions(isResto: false, status: SaleStatus.completed),
          isNot(contains(OrderAction.editOrder)));
    });

    test('11 bis · JAMAIS en restauration, sur aucun statut', () {
      // « Commander » y crée une nouvelle commande au lieu de modifier celle
      // chargée : proposer l'action DUPLIQUAIT la commande (26/09/2026).
      for (final s in SaleStatus.values) {
        for (final appro in [true, false]) {
          expect(actions(status: s, isApprovalSale: appro),
              isNot(contains(OrderAction.editOrder)),
              reason: '$s${appro ? ' (tournée)' : ''}');
        }
      }
    });

    test('12 · supprimer : statut autorisé ET rien d\'encaissé', () {
      for (final s in [
        SaleStatus.scheduled,
        SaleStatus.refused,
        SaleStatus.cancelled,
      ]) {
        expect(actions(status: s), contains(OrderAction.deleteOrder),
            reason: '$s est supprimable');
      }
      // `processing` est exclu du set : son stock est déjà sorti.
      expect(actions(status: SaleStatus.processing),
          isNot(contains(OrderAction.deleteOrder)));
      expect(actions(status: SaleStatus.completed),
          isNot(contains(OrderAction.deleteOrder)));
      expect(actions(canDelete: false),
          isNot(contains(OrderAction.deleteOrder)));
      // Un seul franc encaissé ferme la porte.
      expect(actions(amountPaid: 1),
          isNot(contains(OrderAction.deleteOrder)));
    });
  });

  group('Les maxima simultanés', () {
    test('programmée : une principale et trois secondaires', () {
      expect(actions(status: SaleStatus.scheduled), [
        OrderAction.advanceStatus,
        OrderAction.cancelOrRefuse,
        OrderAction.relaunchClient,
        OrderAction.deleteOrder,
      ]);
    });

    test('encaissée avec reste dû : quatre', () {
      expect(actions(status: SaleStatus.completed, amountDue: 2000), [
        OrderAction.reopenPaidSale,
        OrderAction.invoicePdf,
        OrderAction.invoiceWhatsApp,
        OrderAction.collectBalance,
      ]);
    });

    test('tournée ouverte : la branche dédiée ne dépasse pas cinq', () {
      expect(actions(isApprovalSale: true), [
        OrderAction.closeApprovalRound,
        OrderAction.cancelApprovalRound,
        OrderAction.relaunchClient,
        OrderAction.deleteOrder,
      ]);
      // En e-commerce, la modification reste proposée.
      expect(actions(isApprovalSale: true, isResto: false),
          contains(OrderAction.editOrder));
    });

    test('LE PLAFOND RÉEL, balayé sur toutes les combinaisons', () {
      var toutes = 0;
      var enResto = 0;
      for (final s in SaleStatus.values) {
        for (final appro in [true, false]) {
          for (final due in [0.0, 1500.0]) {
            for (final paid in [0.0, 500.0]) {
              for (final src in [null, 'web']) {
                for (final confirm in [true, false]) {
                  for (final resto in [true, false]) {
                    final n = actions(
                      status: s, isApprovalSale: appro, amountDue: due,
                      amountPaid: paid, source: src,
                      canConfirmClient: confirm, isResto: resto,
                    ).length;
                    if (n > toutes) toutes = n;
                    if (resto && n > enResto) enResto = n;
                  }
                }
              }
            }
          }
        }
      }
      // SEPT en théorie : les combinaisons à sept exigent `isResto: false`,
      // qui seul débloque `editFees`.
      expect(toutes, 7);
      // SIX EN RESTAURATION (jusqu'au 26/09/2026), et c'est le seul chiffre
      // qui gouverne la rangée :
      // `_buildRestoCard` n'est atteinte que si `_isResto`, donc le `!isResto`
      // de `editFees` y est toujours faux. Le bouton « Modifier les frais » ne
      // s'y affiche JAMAIS — sa condition y est du code mort, conservée telle
      // quelle parce que l'extraction ne change aucune règle.
      //
      // SIX, C'EST CE QUI JUSTIFIE LA REFONTE : l'ancien `Row` alignait une
      // action principale de 195 px et cinq icônes de 30 px, écarts compris
      // 381 px — dans une tuile de grille qui n'en offre que 311.
      //
      // CINQ depuis le 26/09/2026 : « Modifier la commande » n'est plus
      // proposé en restauration (il dupliquait la commande).
      expect(enResto, 5);
    });
  });

  group('Le contrat de l\'énumération', () {
    test('une seule action passe par le PIN gérant', () {
      expect(OrderAction.values.where((a) => a.pinGated),
          [OrderAction.reopenPaidSale]);
    });

    test('trois actions sont destructives', () {
      expect(OrderAction.values.where((a) => a.destructive), [
        OrderAction.cancelApprovalRound,
        OrderAction.cancelOrRefuse,
        OrderAction.deleteOrder,
      ]);
    });

    test('aucune action n\'est muette', () {
      for (final a in OrderAction.values) {
        expect(a.label.trim(), isNotEmpty, reason: '$a n\'a pas de libellé');
      }
    });
  });
}
