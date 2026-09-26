// Un F5 vidait le panier, et le remède écrit ne marchait pas.
//
// `saveCart` et `loadCart` existaient dans `sale_local_datasource`, sans un
// seul appelant ni l'un ni l'autre. Et les deux moitiés ne se parlaient pas :
// l'écriture posait dix clés (`product_name`, `unit_price`, `quantity`…), la
// lecture en cherchait quatre sous d'autres noms (`name`, `price`, `qty`).
// Trois des quatre n'existaient pas dans ce qui avait été écrit, et
// `e['name'] as String` sur un `null` LÈVE une erreur de type.
//
// Même avec les bons noms, six champs manquaient à la relecture —
// `customPrice` en tête, c'est-à-dire le prix négocié d'un plat, et
// `priceBuy`, dont dépend toute la marge. Un panier restauré aurait vendu au
// prix catalogue un plat remisé.
//
// Ce que ces tests exigent : l'aller-retour à l'identique, et une clé PAR
// BOUTIQUE.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/caisse/domain/cart_codec.dart';
import 'package:fortress/features/caisse/domain/entities/sale_item.dart';

/// Une ligne qui porte TOUT ce qu'une ligne peut porter — c'est le seul cas
/// qui prouve quelque chose. Une ligne minimale passerait n'importe quel
/// sérialiseur, y compris celui qui perdait six champs.
const _full = SaleItem(
  productId: 'p_ndole',
  productName: 'Ndolè royal',
  variantName: 'Grande part',
  imageUrl: 'https://example.test/ndole.jpg',
  unitPrice: 3500,
  customPrice: 3000,
  priceBuy: 1200,
  quantity: 3,
  discount: 10,
  modifiers: [
    {'group': 'Cuisson', 'option': 'Bien cuit', 'price_impact': 0},
  ],
);

void main() {
  group('L\'aller-retour', () {
    test('UNE LIGNE COMPLÈTE REVIENT À L\'IDENTIQUE', () {
      // LE test de ce lot.
      final back = cartItemFromMap(cartItemToMap(_full));
      expect(back, _full);
    });

    test('le prix négocié survit', () {
      // Le champ qui coûtait de l'argent : sans lui, un plat remisé à 3 000
      // repartait à 3 500 au prochain F5.
      final back = cartItemFromMap(cartItemToMap(_full))!;
      expect(back.customPrice, 3000);
      expect(back.effectivePrice, 3000);
    });

    test('le prix d\'achat survit, donc la marge aussi', () {
      final back = cartItemFromMap(cartItemToMap(_full))!;
      expect(back.priceBuy, 1200);
      expect(back.profitPerUnit, 3000 - 1200);
    });

    test('la variante, l\'image, la remise et les options survivent', () {
      final back = cartItemFromMap(cartItemToMap(_full))!;
      expect(back.variantName, 'Grande part');
      expect(back.imageUrl, 'https://example.test/ndole.jpg');
      expect(back.discount, 10);
      expect(back.modifiers.single['option'], 'Bien cuit');
    });

    test('le sous-total se recalcule au même chiffre', () {
      final back = cartItemFromMap(cartItemToMap(_full))!;
      expect(back.subtotal, _full.subtotal);
    });

    test('une ligne minimale revient aussi', () {
      const bare = SaleItem(
          productId: 'p_eau', productName: 'Eau', unitPrice: 500, quantity: 1);
      expect(cartItemFromMap(cartItemToMap(bare)), bare);
    });
  });

  group('Ce qui manque, et ce qui ne se devine pas', () {
    test('les clés absentes retombent sur les défauts', () {
      // Un panier écrit par une version antérieure du format.
      final back = cartItemFromMap({'product_id': 'p_x', 'quantity': 2})!;
      expect(back.productName, '');
      expect(back.unitPrice, 0);
      expect(back.priceBuy, 0);
      expect(back.customPrice, isNull);
      expect(back.modifiers, isEmpty);
    });

    test('sans identifiant, la ligne ne désigne rien → null', () {
      // Et surtout PAS un article fantôme à zéro, qui partirait en cuisine.
      expect(cartItemFromMap({'quantity': 2}), isNull);
      expect(cartItemFromMap({'product_id': '', 'quantity': 2}), isNull);
    });

    test('sans quantité, la ligne ne désigne rien → null', () {
      expect(cartItemFromMap({'product_id': 'p_x'}), isNull);
    });

    test('les options mal formées ne font pas tomber la lecture', () {
      final back = cartItemFromMap({
        'product_id': 'p_x',
        'quantity': 1,
        'modifiers': 'pas une liste',
      })!;
      expect(back.modifiers, isEmpty);
    });
  });

  group('La clé est PAR BOUTIQUE', () {
    test('deux boutiques, deux paniers', () {
      // La clé était `'cart'`, littérale et unique pour tout l'appareil : un
      // propriétaire à deux boutiques aurait restauré le panier de l'autre —
      // et envoyé en cuisine des plats d'une autre carte.
      expect(cartKeyFor('shop_a'), isNot(cartKeyFor('shop_b')));
    });

    test('la même boutique retrouve toujours la sienne', () {
      expect(cartKeyFor('shop_a'), cartKeyFor('shop_a'));
    });
  });
}
