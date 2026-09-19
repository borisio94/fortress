// Tests de la VENTE À CRÉDIT — dérivation du statut de paiement à la clôture
// et cohérence avec le reste dû (créance client).
//
// La logique métier centrale est `PaymentStatusX.fromAmount(paid, total)` :
// elle décide si une commande clôturée est entièrement payée, partiellement
// payée (créance) ou non payée. On vérifie aussi que le `Sale.amountDue`
// reflète bien la créance résiduelle une fois le statut posé.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/caisse/domain/entities/sale.dart';
import 'package:fortress/features/caisse/domain/entities/sale_item.dart';

Sale _sale({required double unitPrice, required double amountPaid,
    required PaymentStatus status}) {
  return Sale(
    id: 'order_1',
    shopId: 'shop_1',
    items: [
      SaleItem(
        productId: 'p1',
        productName: 'Article',
        unitPrice: unitPrice,
        quantity: 1,
      ),
    ],
    status: SaleStatus.completed,
    paymentMethod: PaymentMethod.cash,
    createdAt: DateTime(2026, 1, 1),
    amountPaid: amountPaid,
    paymentStatus: status,
  );
}

void main() {
  group('PaymentStatusX.fromAmount', () {
    test('paiement complet → paid', () {
      expect(PaymentStatusX.fromAmount(10000, 10000), PaymentStatus.paid);
      expect(PaymentStatusX.fromAmount(12000, 10000), PaymentStatus.paid);
    });

    test('rien encaissé → unpaid (crédit total)', () {
      expect(PaymentStatusX.fromAmount(0, 10000), PaymentStatus.unpaid);
    });

    test('acompte partiel → partial (créance)', () {
      expect(PaymentStatusX.fromAmount(4000, 10000), PaymentStatus.partial);
    });

    test('total nul → paid (commande vide considérée soldée)', () {
      expect(PaymentStatusX.fromAmount(0, 0), PaymentStatus.paid);
    });
  });

  group('Sale.amountDue après clôture à crédit', () {
    test('clôture partielle : reste dû = total - encaissé', () {
      final s = _sale(
          unitPrice: 10000, amountPaid: 4000, status: PaymentStatus.partial);
      expect(s.total, 10000);
      expect(s.amountDue, 6000); // créance client
      expect(s.isFullyPaid, isFalse);
    });

    test('clôture sans paiement : reste dû = total', () {
      final s = _sale(
          unitPrice: 10000, amountPaid: 0, status: PaymentStatus.unpaid);
      expect(s.amountDue, 10000);
      expect(s.isFullyPaid, isFalse);
    });

    test('clôture entièrement payée : reste dû = 0', () {
      final s = _sale(
          unitPrice: 10000, amountPaid: 10000, status: PaymentStatus.paid);
      expect(s.amountDue, 0);
      expect(s.isFullyPaid, isTrue);
    });
  });
}
