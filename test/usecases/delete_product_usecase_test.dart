// Tests unitaires du DeleteProductUseCase (hotfix_085).
//
// Stratégie : on couvre l'intégralité du contrat public SANS toucher
// à Hive ni à Supabase.
//   • `peekBlocker(product)` est testable directement sur un Product
//     synthétique (lecture des compteurs de l'entité).
//   • `call(productId, reason)` lève les exceptions de validation
//     AVANT toute lecture Hive : motif < 10 → throw.
//
// Les chemins qui appellent `AppDatabase.deleteProduct` (statique +
// dépendant de Hive) sont hors scope ici — testés en intégration.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/inventaire/domain/entities/product.dart';
import 'package:fortress/features/inventaire/domain/usecases/delete_product_usecase.dart';

ProductVariant _v({
  String id = 'var_1',
  String name = 'Default',
  int available = 0,
  int physical  = 0,
  int blocked   = 0,
}) =>
    ProductVariant(
      id:             id,
      name:           name,
      stockAvailable: available,
      stockPhysical:  physical,
      stockBlocked:   blocked,
    );

Product _product({
  String id = 'prod_1',
  String name = 'Produit Test',
  List<ProductVariant> variants = const [],
  int stockQty = 0,
}) =>
    Product(
      id:       id,
      storeId:  'shop_test',
      name:     name,
      stockQty: stockQty,
      variants: variants,
    );

void main() {
  group('DeleteProductUseCase.peekBlocker', () {
    test('retourne null quand toutes les variantes sont à zéro', () {
      final useCase = DeleteProductUseCase();
      final product = _product(variants: [
        _v(id: 'v1', available: 0, physical: 0),
        _v(id: 'v2', available: 0, physical: 0),
      ]);
      expect(useCase.peekBlocker(product), isNull);
    });

    test('retourne null pour un produit sans variantes ET stockQty=0', () {
      final useCase = DeleteProductUseCase();
      final product = _product(stockQty: 0);
      expect(useCase.peekBlocker(product), isNull);
    });

    test('retourne ProductNotDeletableException si stock_available > 0',
        () {
      final useCase = DeleteProductUseCase();
      final product = _product(variants: [
        _v(id: 'v1', available: 3, physical: 3),
        _v(id: 'v2', available: 0, physical: 0),
      ]);
      final blocker = useCase.peekBlocker(product);
      expect(blocker, isNotNull);
      expect(blocker!.totalAvailable, 3);
      expect(blocker.productName, 'Produit Test');
    });

    test('retourne blocker si stock_physical > 0 même avec available=0', () {
      // Cas : produit a du stock bloqué (incidents) → ne devrait pas être
      // supprimé non plus, car les unités physiques existent encore.
      final useCase = DeleteProductUseCase();
      final product = _product(variants: [
        _v(id: 'v1', available: 0, physical: 5, blocked: 5),
      ]);
      final blocker = useCase.peekBlocker(product);
      expect(blocker, isNotNull);
      expect(blocker!.totalPhysical, 5);
    });

    test('blocker.message contient des détails actionnables', () {
      final useCase = DeleteProductUseCase();
      final product = _product(variants: [
        _v(id: 'v1', available: 2, physical: 2),
      ]);
      final blocker = useCase.peekBlocker(product)!;
      expect(blocker.message, contains('Stock restant'));
      expect(blocker.message, contains('2'));
    });
  });

  group('DeleteProductUseCase.call — validations préalables', () {
    test('throws MotifSuppressionProduitRequiredException si motif < 10',
        () async {
      final useCase = DeleteProductUseCase();
      // Throw AVANT toute lecture Hive ou auth Supabase. Pas besoin de
      // setup Hive — le check motif est en première position.
      await expectLater(
        useCase.call(productId: 'prod_x', reason: 'court'),
        throwsA(isA<MotifSuppressionProduitRequiredException>()),
      );
    });

    test('throws aussi pour un motif vide ou whitespace', () async {
      final useCase = DeleteProductUseCase();
      await expectLater(
        useCase.call(productId: 'prod_x', reason: '   '),
        throwsA(isA<MotifSuppressionProduitRequiredException>()),
      );
    });
  });

  group('DeleteProductUseCase — contrat des exceptions', () {
    test('MotifSuppressionProduitRequiredException : code + message', () {
      const e = MotifSuppressionProduitRequiredException();
      expect(e.code, 'motif_required');
      expect(e.message, contains('10 caractères'));
      expect(e, isA<DeleteProductException>());
    });

    test('PermissionInsuffisanteException : code + message', () {
      const e = PermissionInsuffisanteException();
      expect(e.code, 'permission_insuffisante');
      expect(e.message, isNotEmpty);
      expect(e, isA<DeleteProductException>());
    });

    test('minReasonLength est aligné avec la RPC SQL (>= 10)', () {
      expect(DeleteProductUseCase.minReasonLength, 10);
    });

    test('ProductNotDeletableException expose `code` "produit_en_stock"',
        () {
      const e = ProductNotDeletableException(productName: 'Test');
      expect(e.code, 'produit_en_stock');
      // Compatibilité legacy — ProductNotDeletableException existe depuis
      // GF-8 (hotfix_083). N'implémente PAS DeleteProductException, gérée
      // séparément par le dialog.
    });
  });
}
