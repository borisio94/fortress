// Le lien « Encaisser & finaliser » de la tuile de grille ne doit apparaître
// que là où le bouton de la carte dépliée existe déjà : même condition, même
// source (`orderActionsFor`).

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/caisse/domain/entities/sale.dart';
import 'package:fortress/features/restaurant/domain/order_actions.dart';

List<OrderAction> acts(
  SaleStatus status, {
  bool isApprovalSale = false,
  bool canConfirmClient = false,
  bool isResto = true,
}) =>
    orderActionsFor(
      status: status,
      isApprovalSale: isApprovalSale,
      amountDue: 5000,
      amountPaid: 0,
      source: 'pos',
      canCancel: true,
      canEdit: true,
      canDelete: true,
      isResto: isResto,
      canConfirmClient: canConfirmClient,
    );

void main() {
  test('une commande de restaurant ouverte propose l\'encaissement', () {
    expect(settleOffered(acts(SaleStatus.processing), isResto: true), isTrue);
    expect(settleOffered(acts(SaleStatus.scheduled), isResto: true), isTrue);
  });

  test('une commande encaissée ou sans suite ne le propose plus', () {
    for (final s in [
      SaleStatus.completed,
      SaleStatus.cancelled,
      SaleStatus.refused,
      SaleStatus.refunded,
    ]) {
      expect(settleOffered(acts(s), isResto: true), isFalse, reason: s.name);
    }
  });

  test('une tournée « à choisir » a sa propre clôture, pas d\'encaissement', () {
    expect(
        settleOffered(acts(SaleStatus.processing, isApprovalSale: true),
            isResto: true),
        isFalse);
  });

  test('une confirmation client en attente bloque, comme le bouton déplié', () {
    expect(
        settleOffered(acts(SaleStatus.scheduled, canConfirmClient: true),
            isResto: true),
        isFalse);
  });

  test('hors restauration, le même bouton n\'encaisse pas : jamais proposé', () {
    // En e-commerce, `advanceStatus` sur une commande programmée démarre la
    // livraison. Ce n'est pas un encaissement.
    expect(
        settleOffered(acts(SaleStatus.scheduled, isResto: false),
            isResto: false),
        isFalse);
  });
}
