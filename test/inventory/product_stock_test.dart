// Tests unitaires purs sur Product / ProductVariant — pas de Hive ni Supabase.
// Couvre :
//   T06 — créer produit 4 variantes × 5 → totalStock == 20
//   T07 — totalStock == somme(variantes.stockAvailable) toujours (invariant)
//   T08 — arrivée +3 sur variante A → varianteA.stockAvailable == 8 ET total == 23
import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/inventaire/domain/entities/product.dart';

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
  group('Product.totalStock', () {
    test('T06 — 4 variantes × 5 → totalStock == 20', () {
      final p = _productWith([
        _v('A', 5), _v('B', 5), _v('C', 5), _v('D', 5),
      ]);
      expect(p.totalStock, 20);
    });

    test('T07 — invariant : totalStock == somme(variantes.stockAvailable)', () {
      // Plusieurs configurations aléatoires → l'invariant tient toujours.
      final cases = <List<int>>[
        [0, 0, 0, 0],
        [10, 0, 5, 0],
        [3, 7, 11, 1],
        [42, 1, 0, 99],
        [5, 5, 5, 5],
      ];
      for (final stocks in cases) {
        final variants = [
          for (int i = 0; i < stocks.length; i++) _v('v$i', stocks[i]),
        ];
        final p = _productWith(variants);
        final expected = stocks.fold<int>(0, (s, x) => s + x);
        expect(p.totalStock, expected,
            reason: 'totalStock doit refléter la somme exacte pour $stocks');
      }
    });

    test('T08 — arrivée +3 sur variante A → A.stockAvailable=8 ET total=23',
        () {
      // État initial : 4 variantes × 5 = 20.
      final initial = _productWith([
        _v('A', 5), _v('B', 5), _v('C', 5), _v('D', 5),
      ]);
      expect(initial.totalStock, 20);

      // Reproduit le comportement de StockService.arrivalAvailable : la
      // variante touchée passe de 5 → 8 via copyWith. Les autres ne bougent
      // pas. Le total est dérivé automatiquement par le getter Product.
      final variantsAfter = [
        initial.variants[0].copyWith(
          stockAvailable: initial.variants[0].stockAvailable + 3,
          stockPhysical:  initial.variants[0].stockPhysical  + 3,
        ),
        initial.variants[1],
        initial.variants[2],
        initial.variants[3],
      ];
      final after = initial.copyWith(variants: variantsAfter);

      expect(after.variants[0].stockAvailable, 8,
          reason: 'variante A doit passer à 8');
      expect(after.totalStock, 23, reason: '20 + 3 = 23');
    });
  });

  group('Product sans variantes (legacy)', () {
    test('totalStock retombe sur stockQty quand pas de variantes', () {
      const p = Product(
        id:       'prod_legacy',
        storeId:  'shop_test',
        name:     'Legacy',
        stockQty: 12,
      );
      expect(p.totalStock, 12);
    });
  });
}
