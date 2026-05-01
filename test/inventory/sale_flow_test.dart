// Tests unitaires purs des transitions d'état lors d'une vente — sans Hive
// ni Supabase. Reproduit la logique de StockService.sale / reverseSale au
// niveau entité (ProductVariant.copyWith). Tout passage par Hive ou par les
// boxes statiques d'AppDatabase est volontairement absent : les invariants
// testés ici sont MATHÉMATIQUES sur l'entité.
//
// Couvre :
//   T09 — vendre 1 variante A + 1 variante B → totalStock == 18 (pas 19)
//   T10 — annuler vente T09 → totalStock == 20 (pas 21)
//   T11 — vendre plus que stock → refusé · stock inchangé
import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/inventaire/domain/entities/product.dart';

// ── Helpers : reproduisent en pur Dart les transitions de StockService ───

/// Pré-condition de vente : `quantity` doit être ≤ `stockAvailable`.
bool canSell(ProductVariant v, int qty) => v.stockAvailable >= qty;

/// Applique une vente sur la variante. Retourne la variante mise à jour.
/// Throw si stock insuffisant — c'est le contrat attendu côté UI :
/// l'appelant doit pré-vérifier via [canSell] OU gérer l'exception.
ProductVariant applySale(ProductVariant v, int qty) {
  if (!canSell(v, qty)) {
    throw StateError(
        'Stock insuffisant : demandé $qty, disponible ${v.stockAvailable}');
  }
  return v.copyWith(
    stockAvailable: v.stockAvailable - qty,
    stockPhysical:  v.stockPhysical  - qty,
  );
}

/// Annule une vente : restore stockAvailable et stockPhysical.
/// Reproduit StockService.reverseSale au niveau entité.
ProductVariant reverseSale(ProductVariant v, int qty) => v.copyWith(
      stockAvailable: v.stockAvailable + qty,
      stockPhysical:  v.stockPhysical  + qty,
    );

ProductVariant _v(String name, int stock) => ProductVariant(
      id:             'var_$name',
      name:           name,
      stockAvailable: stock,
      stockPhysical:  stock,
    );

Product _productWith(List<ProductVariant> variants) => Product(
      id:       'prod_test',
      storeId:  'shop_test',
      name:     'Produit Test',
      variants: variants,
    );

void main() {
  group('Vente — transitions de stock', () {
    test('T09 — vendre 1 variante A + 1 variante B → total=18 (pas 19)', () {
      final initial = _productWith([
        _v('A', 5), _v('B', 5), _v('C', 5), _v('D', 5),
      ]);
      expect(initial.totalStock, 20);

      // Vendre 1 unité sur A (5 → 4) puis 1 unité sur B (5 → 4).
      final afterA = applySale(initial.variants[0], 1);
      final afterB = applySale(initial.variants[1], 1);
      final updated = initial.copyWith(variants: [
        afterA, afterB, initial.variants[2], initial.variants[3],
      ]);

      expect(afterA.stockAvailable, 4);
      expect(afterB.stockAvailable, 4);
      expect(updated.totalStock, 18,
          reason: '20 - 1 - 1 = 18, pas 19 (deux variantes touchées)');
    });

    test('T10 — annuler la vente précédente → total=20 (pas 21)', () {
      // On part de l'état post-vente : A=4, B=4, C=5, D=5 (total=18).
      final postSale = _productWith([
        _v('A', 4), _v('B', 4), _v('C', 5), _v('D', 5),
      ]);
      expect(postSale.totalStock, 18);

      // Annulation : on restaure 1 sur A et 1 sur B.
      final restoredA = reverseSale(postSale.variants[0], 1);
      final restoredB = reverseSale(postSale.variants[1], 1);
      final restored = postSale.copyWith(variants: [
        restoredA, restoredB, postSale.variants[2], postSale.variants[3],
      ]);

      expect(restoredA.stockAvailable, 5);
      expect(restoredB.stockAvailable, 5);
      expect(restored.totalStock, 20,
          reason: '18 + 1 + 1 = 20, pas 21 (annulation symétrique)');
    });

    test('T11 — vendre plus que stock → exception · stock inchangé', () {
      final variantA = _v('A', 5);
      // Stock initial mémorisé pour vérifier l'inchangé après l'échec.
      final stockBefore = variantA.stockAvailable;

      expect(() => applySale(variantA, 6), throwsStateError,
          reason: 'demander 6 alors qu\'il y en a 5 doit refuser');

      // L'entité est immutable : elle n'a pas pu être modifiée.
      expect(variantA.stockAvailable, stockBefore,
          reason: 'stock doit rester inchangé après tentative refusée');

      // Pré-condition explicite cohérente.
      expect(canSell(variantA, 6), isFalse);
      expect(canSell(variantA, 5), isTrue);
      expect(canSell(variantA, 0), isTrue);
    });
  });
}
