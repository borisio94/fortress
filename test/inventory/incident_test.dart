// Test pur : T12 — marquer une variante "damaged" doit décrémenter le stock
// disponible, augmenter le stock bloqué (le total physique reste constant)
// ET créer un incident pending.
//
// Reproduit en Dart la logique de StockService.blockExisting au niveau
// entité, sans Hive : on vérifie l'invariant
//   physical = available + blocked
// avant et après le blocage, et on vérifie la création de l'Incident.
import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/inventaire/domain/entities/incident.dart';
import 'package:fortress/features/inventaire/domain/entities/product.dart';

({ProductVariant updated, Incident incident}) markDamaged({
  required ProductVariant variant,
  required int quantity,
  required String shopId,
  required String productId,
  required String productName,
  required String cause,
}) {
  if (variant.stockAvailable < quantity) {
    throw StateError(
        'Stock disponible insuffisant : demandé $quantity, '
        'disponible ${variant.stockAvailable}');
  }
  final updated = variant.copyWith(
    stockAvailable: variant.stockAvailable - quantity,
    stockBlocked:   variant.stockBlocked   + quantity,
    // physical inchangé : les unités sont toujours là, juste pas vendables.
  );
  final incident = Incident(
    id:          'inc_test_${DateTime.now().microsecondsSinceEpoch}',
    shopId:      shopId,
    productId:   productId,
    variantId:   variant.id,
    productName: productName,
    type:        IncidentType.scrapped, // damaged → scrapped (cf. blockExisting)
    quantity:    quantity,
    notes:       'Incident damaged — $cause',
    createdAt:   DateTime.now(),
  );
  return (updated: updated, incident: incident);
}

void main() {
  group('T12 — Marquer une variante damaged', () {
    test('stock available diminue · blocked augmente · physical inchangé', () {
      const original = ProductVariant(
        id:             'var_A',
        name:           'A',
        stockAvailable: 10,
        stockBlocked:   0,
        stockPhysical:  10,
      );

      final result = markDamaged(
        variant:     original,
        quantity:    3,
        shopId:      'shop_1',
        productId:   'prod_1',
        productName: 'Produit Test',
        cause:       'casse en transport',
      );

      expect(result.updated.stockAvailable, 7,
          reason: '10 - 3 unités damaged → 7 disponibles');
      expect(result.updated.stockBlocked, 3,
          reason: '0 + 3 → 3 unités bloquées (à inspecter / réparer / rebut)');
      expect(result.updated.stockPhysical, 10,
          reason: 'physical inchangé : les unités sont toujours sur place');

      // Invariant fondamental : physical == available + blocked.
      expect(result.updated.stockPhysical,
          result.updated.stockAvailable + result.updated.stockBlocked,
          reason: 'invariant comptable physical = available + blocked');
    });

    test('un incident est créé avec status=pending et type=scrapped', () {
      const original = ProductVariant(
        id:             'var_A',
        name:           'A',
        stockAvailable: 10,
        stockPhysical:  10,
      );

      final result = markDamaged(
        variant:     original,
        quantity:    2,
        shopId:      'shop_1',
        productId:   'prod_1',
        productName: 'Produit Test',
        cause:       'choc à l\'arrivée',
      );

      expect(result.incident.status, IncidentStatus.pending,
          reason: 'un incident frais doit être pending');
      expect(result.incident.type, IncidentType.scrapped,
          reason: 'damaged → IncidentType.scrapped (cf. StockService:119)');
      expect(result.incident.quantity, 2);
      expect(result.incident.shopId, 'shop_1');
      expect(result.incident.productId, 'prod_1');
      expect(result.incident.variantId, 'var_A');
      expect(result.incident.notes, contains('damaged'));
      expect(result.incident.notes, contains('choc'));
      expect(result.incident.isPending, isTrue);
      expect(result.incident.isResolved, isFalse);
    });

    test('refuse de bloquer plus que le disponible · stock inchangé', () {
      const original = ProductVariant(
        id:             'var_A',
        name:           'A',
        stockAvailable: 2,
        stockPhysical:  2,
      );

      expect(
        () => markDamaged(
          variant:     original,
          quantity:    5,
          shopId:      'shop_1',
          productId:   'prod_1',
          productName: 'Produit Test',
          cause:       'invalide',
        ),
        throwsStateError,
      );
      // L'entité est immutable, son état n'a pas pu être modifié.
      expect(original.stockAvailable, 2);
      expect(original.stockBlocked, 0);
    });
  });
}
