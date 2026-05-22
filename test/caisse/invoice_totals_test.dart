// Tests des calculs financiers de Sale — la base de la facture PDF.
// Aucune dépendance Hive/Supabase : ce sont des getters purs sur
// l'entité (subtotal, taxAmount, total, amountDue, isFullyPaid).
//
// Enjeu : ces montants sont imprimés sur la facture remise au client.
// Une erreur de calcul (remise appliquée après TVA, frais ajoutés au
// total, reste dû négatif…) est directement visible et litigieuse.
// Invariant métier clé (cf. Sale.total) : les `fees` sont ABSORBÉS par
// la boutique et ne s'ajoutent PAS au prix facturé.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/caisse/domain/entities/sale.dart';
import 'package:fortress/features/caisse/domain/entities/sale_item.dart';

SaleItem _item({
  required double unitPrice,
  required int qty,
  double discount = 0,
  double? customPrice,
}) =>
    SaleItem(
      productId: 'p',
      productName: 'Produit',
      unitPrice: unitPrice,
      quantity: qty,
      discount: discount,
      customPrice: customPrice,
    );

Sale _sale({
  required List<SaleItem> items,
  double discountAmount = 0,
  double taxRate = 0,
  List<Map<String, dynamic>> fees = const [],
  double amountPaid = 0,
  PaymentStatus paymentStatus = PaymentStatus.unpaid,
}) =>
    Sale(
      id: 'order_1',
      shopId: 'shop_1',
      items: items,
      discountAmount: discountAmount,
      taxRate: taxRate,
      fees: fees,
      paymentMethod: PaymentMethod.cash,
      createdAt: DateTime(2026, 5, 22),
      amountPaid: amountPaid,
      paymentStatus: paymentStatus,
    );

void main() {
  group('subtotal', () {
    test('somme des lignes (prix × qté)', () {
      final s = _sale(items: [
        _item(unitPrice: 1000, qty: 2), // 2000
        _item(unitPrice: 500, qty: 3),  // 1500
      ]);
      expect(s.subtotal, 3500);
    });

    test('remise par ligne appliquée avant le total', () {
      final s = _sale(items: [
        _item(unitPrice: 1000, qty: 1, discount: 10), // 900
      ]);
      expect(s.subtotal, 900);
    });

    test('customPrice écrase unitPrice', () {
      final s = _sale(items: [
        _item(unitPrice: 1000, qty: 2, customPrice: 800), // 1600
      ]);
      expect(s.subtotal, 1600);
    });
  });

  group('TVA et total', () {
    test('sans TVA ni remise → total = subtotal', () {
      final s = _sale(items: [_item(unitPrice: 2000, qty: 1)]);
      expect(s.taxAmount, 0);
      expect(s.total, 2000);
    });

    test('TVA 19.25 % appliquée après remise globale', () {
      final s = _sale(
        items: [_item(unitPrice: 10000, qty: 1)],
        discountAmount: 2000, // base taxable = 8000
        taxRate: 19.25,
      );
      // taxAmount = (10000 - 2000) * 0.1925 = 1540
      expect(s.taxAmount, closeTo(1540, 0.001));
      // total = 10000 - 2000 + 1540 = 9540
      expect(s.total, closeTo(9540, 0.001));
    });

    test('les frais (fees) ne sont PAS ajoutés au total facturé', () {
      final s = _sale(
        items: [_item(unitPrice: 5000, qty: 1)],
        fees: [
          {'id': 'f1', 'label': 'Livraison', 'amount': 1500},
        ],
      );
      expect(s.totalFees, 1500);
      // Invariant : total ignore les fees (absorbés par la boutique).
      expect(s.total, 5000);
    });
  });

  group('amountDue / isFullyPaid', () {
    test('rien payé → reste dû = total', () {
      final s = _sale(items: [_item(unitPrice: 3000, qty: 1)]);
      expect(s.amountDue, 3000);
      expect(s.isFullyPaid, isFalse);
    });

    test('acompte partiel → reste dû = total - acompte', () {
      final s = _sale(
        items: [_item(unitPrice: 3000, qty: 1)],
        amountPaid: 1000,
        paymentStatus: PaymentStatus.partial,
      );
      expect(s.amountDue, 2000);
      expect(s.isFullyPaid, isFalse);
    });

    test('statut payé → reste dû = 0 même si amountPaid non peuplé', () {
      // Couvre les commandes legacy pré-hotfix_065 (amountPaid = 0 mais
      // paymentStatus = paid).
      final s = _sale(
        items: [_item(unitPrice: 3000, qty: 1)],
        amountPaid: 0,
        paymentStatus: PaymentStatus.paid,
      );
      expect(s.amountDue, 0);
      expect(s.isFullyPaid, isTrue);
    });

    test('reste dû jamais négatif (sur-paiement)', () {
      final s = _sale(
        items: [_item(unitPrice: 2000, qty: 1)],
        amountPaid: 2500, // payé plus que dû
        paymentStatus: PaymentStatus.partial,
      );
      expect(s.amountDue, greaterThanOrEqualTo(0));
      expect(s.amountDue, 0);
    });
  });
}
