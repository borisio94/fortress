import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/services/entity_cascade.dart';

/// Vérifie la propagation de l'édition d'un produit vers les snapshots des
/// lignes de commande : le nom et l'image se répercutent, le PRIX reste figé.
void main() {
  Map<String, dynamic> order() => {
        'id': 'o1',
        'items': [
          {'product_id': 'p1', 'product_name': 'Ancien', 'image_url': 'old.png',
           'unit_price': 1000},
          {'product_id': 'p2', 'product_name': 'Autre',  'image_url': 'x.png',
           'unit_price': 500},
        ],
      };

  group('EntityCascade.applyProductIdentityToOrder', () {
    test('propage nom + image sur les lignes du produit ciblé', () {
      final o = order();
      final changed = EntityCascade.applyProductIdentityToOrder(o,
          productId: 'p1', newName: 'Nouveau', newImageUrl: 'new.png');
      expect(changed, isTrue);
      final items = o['items'] as List;
      expect(items[0]['product_name'], 'Nouveau');
      expect(items[0]['image_url'], 'new.png');
      // Autre produit intact.
      expect(items[1]['product_name'], 'Autre');
    });

    test('ne touche JAMAIS le prix (intégrité comptable)', () {
      final o = order();
      EntityCascade.applyProductIdentityToOrder(o,
          productId: 'p1', newName: 'Nouveau', newImageUrl: 'new.png');
      expect((o['items'] as List)[0]['unit_price'], 1000);
    });

    test('retourne false si rien ne change (produit absent)', () {
      final o = order();
      final changed = EntityCascade.applyProductIdentityToOrder(o,
          productId: 'inexistant', newName: 'X', newImageUrl: 'y.png');
      expect(changed, isFalse);
    });

    test('retourne false si nom/image identiques', () {
      final o = order();
      final changed = EntityCascade.applyProductIdentityToOrder(o,
          productId: 'p1', newName: 'Ancien', newImageUrl: 'old.png');
      expect(changed, isFalse);
    });

    test('commande sans items → no-op', () {
      final o = {'id': 'o2'};
      expect(
          EntityCascade.applyProductIdentityToOrder(o,
              productId: 'p1', newName: 'X', newImageUrl: 'y'),
          isFalse);
    });
  });

  group('EntityCascade.renameProductField', () {
    test('renomme la catégorie/marque référencée par nom', () {
      final p = {'category_id': 'Boissons', 'brand': 'Coca'};
      expect(
          EntityCascade.renameProductField(p, 'category_id', 'Boissons', 'Sodas'),
          isTrue);
      expect(p['category_id'], 'Sodas');
    });
    test('ne touche pas un produit d\'une autre catégorie', () {
      final p = {'category_id': 'Snacks'};
      expect(
          EntityCascade.renameProductField(p, 'category_id', 'Boissons', 'Sodas'),
          isFalse);
      expect(p['category_id'], 'Snacks');
    });
  });
}
