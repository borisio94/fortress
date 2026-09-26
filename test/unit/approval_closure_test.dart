import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/caisse/domain/approval_closure.dart';
import 'package:fortress/features/caisse/domain/entities/sale.dart';
import 'package:fortress/features/caisse/domain/entities/sale_item.dart';

/// Commande « à choisir sur place » de test : 3 unités de A à 1000 + 2 de B à
/// 500, 500 de livraison. Réservé = 4000 (3×1000 + 2×500 + 500 livraison).
Sale _reservedOrder() => Sale(
      id: 'ord-1',
      shopId: 'shop-1',
      paymentMethod: PaymentMethod.cash,
      createdAt: DateTime(2026, 7, 28),
      status: SaleStatus.scheduled,
      isApprovalSale: true,
      stockReserved: true,
      deliveryPrice: 500,
      items: const [
        SaleItem(
            productId: 'a', productName: 'A', unitPrice: 1000, quantity: 3),
        SaleItem(
            productId: 'b', productName: 'B', unitPrice: 500, quantity: 2),
      ],
    );

/// Reproduit la vente finale construite par
/// `SaleLocalDatasource.closeApprovalOrder` : items ramenés aux quantités
/// gardées, puis encaissement dérivé du montant réellement payé.
Sale _closedSale(Sale order, Map<String, int> kept, {double? amountPaid}) {
  final recon = ApprovalClosure.reconcile(
    reserved: {for (final i in order.items) i.productId: i.quantity},
    kept: kept,
  );
  final keptItems = [
    for (final i in order.items)
      if ((recon.kept[i.productId] ?? 0) > 0)
        i.copyWith(quantity: recon.kept[i.productId]!)
  ];
  if (keptItems.isEmpty) {
    return order.copyWith(
        status: SaleStatus.cancelled, stockReserved: false);
  }
  final base = order.copyWith(
      items: keptItems, status: SaleStatus.completed, stockReserved: false);
  final total = base.total;
  final paid = (amountPaid ?? total).clamp(0, total).toDouble();
  return base.copyWith(
      amountPaid: paid, paymentStatus: PaymentStatusX.fromAmount(paid, total));
}

void main() {
  group('ApprovalClosure.reconcile — vente « à choisir sur place »', () {
    test('tout gardé → rien retourné', () {
      final r = ApprovalClosure.reconcile(
        reserved: {'a': 2, 'b': 1},
        kept: {'a': 2, 'b': 1},
      );
      expect(r.kept, {'a': 2, 'b': 1});
      expect(r.returned, {'a': 0, 'b': 0});
      expect(r.totalKept, 3);
      expect(r.totalReturned, 0);
    });

    test('rien gardé → tout retourné', () {
      final r = ApprovalClosure.reconcile(
        reserved: {'a': 2, 'b': 3},
        kept: {}, // l\'opérateur n\'a coché aucun gardé
      );
      expect(r.kept, {'a': 0, 'b': 0});
      expect(r.returned, {'a': 2, 'b': 3});
      expect(r.totalReturned, 5);
    });

    test('partiel : gardé < réservé → retourné = réservé − gardé', () {
      final r = ApprovalClosure.reconcile(
        reserved: {'a': 5},
        kept: {'a': 2},
      );
      expect(r.kept['a'], 2);
      expect(r.returned['a'], 3);
    });

    test('gardé > réservé → borné au réservé (jamais de stock négatif)', () {
      final r = ApprovalClosure.reconcile(
        reserved: {'a': 2},
        kept: {'a': 99}, // saisie erronée
      );
      expect(r.kept['a'], 2); // borné
      expect(r.returned['a'], 0);
    });

    test('gardé négatif → ramené à 0 → tout retourné', () {
      final r = ApprovalClosure.reconcile(
        reserved: {'a': 3},
        kept: {'a': -5},
      );
      expect(r.kept['a'], 0);
      expect(r.returned['a'], 3);
    });

    test('article réservé à 0 ou négatif → ignoré', () {
      final r = ApprovalClosure.reconcile(
        reserved: {'a': 0, 'b': -1, 'c': 2},
        kept: {'a': 1, 'b': 1, 'c': 1},
      );
      expect(r.kept.containsKey('a'), false);
      expect(r.kept.containsKey('b'), false);
      expect(r.kept['c'], 1);
      expect(r.returned['c'], 1);
    });

    test('clé gardée inconnue (pas dans réservé) → ignorée', () {
      final r = ApprovalClosure.reconcile(
        reserved: {'a': 2},
        kept: {'a': 1, 'zzz': 10}, // 'zzz' n\'a jamais été réservé
      );
      expect(r.kept.keys.toSet(), {'a'});
      expect(r.returned.keys.toSet(), {'a'});
    });

    test('INVARIANT : gardé + retourné == réservé, pour chaque article', () {
      final reserved = {'a': 4, 'b': 7, 'c': 1, 'd': 0, 'e': 10};
      final kept = {'a': 4, 'b': 3, 'c': 0, 'e': 25};
      final r = ApprovalClosure.reconcile(reserved: reserved, kept: kept);
      for (final entry in reserved.entries) {
        if (entry.value <= 0) continue; // ignorés
        final id = entry.key;
        expect(
          (r.kept[id] ?? 0) + (r.returned[id] ?? 0),
          entry.value,
          reason: 'gardé+retourné doit égaler le réservé pour $id',
        );
      }
      // Conservation globale : tout le réservé (positif) est réparti.
      final totalReserved =
          reserved.values.where((v) => v > 0).fold(0, (s, v) => s + v);
      expect(r.totalKept + r.totalReturned, totalReserved);
    });

    test('helpers nonZero filtrent les quantités nulles', () {
      final r = ApprovalClosure.reconcile(
        reserved: {'a': 2, 'b': 2},
        kept: {'a': 2, 'b': 0},
      );
      expect(r.keptNonZero, {'a': 2});
      expect(r.returnedNonZero, {'b': 2});
    });
  });

  // ── Encaissement à la clôture ────────────────────────────────────────────
  // Régression : la clôture court-circuite `updateOrderStatus` (garde-fou
  // stock), elle DOIT donc porter elle-même le volet paiement. Sans lui, la
  // commande arrivait en « terminée » avec amount_paid = 0 / unpaid.
  group('Clôture « à choisir sur place » — encaissement', () {
    test('le total facturé ne porte QUE les articles gardés', () {
      final order = _reservedOrder(); // 3×1000 + 2×500 + 500 livr. = 4500
      expect(order.total, 4500);
      final closed = _closedSale(order, {'a': 1, 'b': 0});
      // 1×1000 + 500 de livraison
      expect(closed.total, 1500);
      expect(closed.items.length, 1);
      expect(closed.items.first.quantity, 1);
    });

    test('clôture soldée → payée intégralement, plus rien à encaisser', () {
      final closed = _closedSale(_reservedOrder(), {'a': 3, 'b': 2});
      expect(closed.status, SaleStatus.completed);
      expect(closed.amountPaid, closed.total);
      expect(closed.paymentStatus, PaymentStatus.paid);
      expect(closed.amountDue, 0);
      expect(closed.stockReserved, false);
    });

    test('encaissement partiel → créance client (partial), pas payée', () {
      final closed =
          _closedSale(_reservedOrder(), {'a': 2, 'b': 1}, amountPaid: 1000);
      expect(closed.total, 3000); // 2×1000 + 1×500 + 500 livraison
      expect(closed.amountPaid, 1000);
      expect(closed.paymentStatus, PaymentStatus.partial);
      expect(closed.amountDue, 2000);
    });

    test('rien encaissé → unpaid mais montant dû exact (acompte possible)',
        () {
      final closed =
          _closedSale(_reservedOrder(), {'a': 1, 'b': 1}, amountPaid: 0);
      expect(closed.paymentStatus, PaymentStatus.unpaid);
      expect(closed.amountDue, closed.total);
    });

    test('montant saisi > total → capé au total (jamais de trop-perçu)', () {
      final closed =
          _closedSale(_reservedOrder(), {'a': 1, 'b': 0}, amountPaid: 999999);
      expect(closed.amountPaid, closed.total);
      expect(closed.paymentStatus, PaymentStatus.paid);
    });

    test('rien gardé → commande annulée, aucun encaissement', () {
      final closed = _closedSale(_reservedOrder(), {'a': 0, 'b': 0});
      expect(closed.status, SaleStatus.cancelled);
      expect(closed.amountPaid, 0);
      expect(closed.stockReserved, false);
    });
  });
}
