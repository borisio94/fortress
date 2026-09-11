// Barre du bas mobile e-commerce : Accueil · Caisse · Stock (+ « Plus »).
//
// CRM a quitté la rangée principale pour le tiroir « Plus » — ces tests
// verrouillent la rangée ET le fait qu'aucune route n'a été supprimée.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/shared/navigation/shell_nav_items.dart';

void main() {
  group('Barre du bas e-commerce', () {
    test('rangée principale = Accueil · Caisse · Stock', () {
      final routes = kShellNavItems
          .where((i) => i.primary && i.matchesSector('ecommerce'))
          .map((i) => i.route('shop_1'))
          .toList();
      expect(routes, [
        '/shop/shop_1/dashboard',
        '/shop/shop_1/caisse',
        '/shop/shop_1/inventaire',
      ]);
    });

    test('CRM reste accessible au menu (non supprimé)', () {
      expect(
        kShellNavItems.any((i) =>
            i.route('shop_1') == '/shop/shop_1/crm' &&
            i.matchesSector('ecommerce')),
        isTrue,
      );
    });
  });
}
