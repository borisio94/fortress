import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/inventaire/domain/usecases/add_product_usecase.dart';

/// À la création d'un produit, la visibilité sur le web doit être activée
/// par défaut (catalogue en ligne). Couvre la voie « ajout rapide »
/// (AddProductParams.toProduct) ; le formulaire complet applique le même
/// défaut côté UI (_isVisibleWeb = true à la création).
void main() {
  test('un produit créé est visible sur le web par défaut', () {
    final p = const AddProductParams(shopId: 's1', name: 'Coca 33cl')
        .toProduct('s1');
    expect(p.isVisibleWeb, isTrue);
  });

  test('les champs de base sont conservés', () {
    final p = const AddProductParams(
      shopId: 's1', name: 'Eau', priceSellPos: 500, stockQty: 10,
    ).toProduct('s1');
    expect(p.name, 'Eau');
    expect(p.isVisibleWeb, isTrue);
  });
}
