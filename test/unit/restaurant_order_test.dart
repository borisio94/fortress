// Tests unitaires du module restaurant — PR-2.
//
// Cible les trois pièges identifiés à l'inspection :
//   1. `Sale.copyWith` résout les nullables par `??` → sans le drapeau
//      `clearTable`, détacher une commande de sa table serait un no-op.
//   2. `SaleItem.copyWith` réassigne chaque champ à la main → un oubli
//      effacerait les options à chaque changement de quantité.
//   3. Le prix des options doit être MATÉRIALISÉ dans `customPrice`, sinon
//      la dizaine de recalculs de total dispersés dans l'app (dashboard,
//      exports, métriques client, tracking web) sous-évaluerait la commande.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/services/restaurant_order_service.dart';
import 'package:fortress/features/caisse/domain/entities/sale.dart';
import 'package:fortress/features/caisse/domain/entities/sale_item.dart';
import 'package:fortress/features/restaurant/domain/entities/menu_modifier.dart';

const _cuisson = <String, dynamic>{
  'group': 'Cuisson',
  'option': 'Saignant',
  'price_impact': 0,
};
const _fromage = <String, dynamic>{
  'group': 'Suppléments',
  'option': 'Fromage',
  'price_impact': 500,
};
const _sansSauce = <String, dynamic>{
  'group': 'Options',
  'option': 'Sans sauce',
  'price_impact': -200,
};

Sale _order({String? tableId = 'rt_1', int? covers = 4}) => Sale(
      id: 'order_1',
      shopId: 'shop_1',
      items: const [],
      paymentMethod: PaymentMethod.cash,
      createdAt: DateTime.utc(2026, 7, 19, 12),
      orderType: 'dine_in',
      tableId: tableId,
      covers: covers,
    );

void main() {
  _pr4Tests();
  group('Sale — champs restauration', () {
    test('défauts non intrusifs pour une vente non-restaurant', () {
      final sale = Sale(
        shopId: 'shop_1',
        items: const [],
        paymentMethod: PaymentMethod.cash,
        createdAt: DateTime.utc(2026, 7, 19),
      );
      // Non-régression e-commerce : une vente créée sans rien préciser ne
      // doit ressembler en rien à une commande de salle.
      expect(sale.tableId, isNull);
      expect(sale.covers, isNull);
      expect(sale.orderType, 'takeaway');
      expect(sale.sentToKitchen, isFalse);
      expect(sale.kitchenReady, isFalse);
      expect(sale.isDineIn, isFalse);
      expect(sale.isInKitchen, isFalse);
    });

    test('clearTable détache réellement la commande de sa table', () {
      // LE piège : `copyWith(tableId: null)` seul est un no-op silencieux
      // parce que le corps résout par `??`. Sans `clearTable`, la commande
      // resterait accrochée à une table déjà libérée après encaissement.
      final order = _order();
      expect(order.copyWith(tableId: null).tableId, 'rt_1',
          reason: 'le ?? ignore un null — comportement attendu du pattern');

      final freed = order.copyWith(clearTable: true);
      expect(freed.tableId, isNull);
      expect(freed.covers, isNull);
      // Le reste de la commande survit au détachement.
      expect(freed.id, 'order_1');
      expect(freed.orderType, 'dine_in');
    });

    test('isDineIn ne cible QUE le service en salle', () {
      // Getter sémantique (filtres, libellés). Il ne pilote PLUS le stock :
      // depuis hotfix_138 c'est `Product.trackStock` qui décide, par ligne
      // et non par canal — cf. restaurant_track_stock_test.dart.
      expect(_order().isDineIn, isTrue);
      for (final type in ['takeaway', 'delivery', 'pos', '']) {
        expect(_order().copyWith(orderType: type).isDineIn, isFalse);
      }
    });

    test('isInKitchen ne vaut que entre l\'envoi et la mise à disposition',
        () {
      final sent = _order().copyWith(sentToKitchen: true);
      expect(sent.isInKitchen, isTrue);
      expect(sent.copyWith(kitchenReady: true).isInKitchen, isFalse);
    });

    test('props inclut les champs cuisine — sinon l\'écran resterait figé',
        () {
      final sent = _order().copyWith(sentToKitchen: true);
      final ready = sent.copyWith(kitchenReady: true);
      // Equatable doit voir la différence, sans quoi le passage
      // « envoyé » → « prêt » ne rebuilderait pas la liste des bons.
      expect(sent == ready, isFalse);
    });
  });

  group('SaleItem — options de menu', () {
    test('modifiers vide par défaut (zéro impact e-commerce)', () {
      const item = SaleItem(
          productId: 'p1', productName: 'Café', unitPrice: 500, quantity: 1);
      expect(item.modifiers, isEmpty);
      expect(item.modifiersKey, '');
      expect(item.modifiersLabel, '');
    });

    test('copyWith conserve les options', () {
      const item = SaleItem(
        productId: 'p1',
        productName: 'Steak',
        unitPrice: 5000,
        quantity: 1,
        modifiers: [_cuisson],
      );
      // Sans la recopie explicite dans le corps de copyWith, un simple
      // changement de quantité effacerait la cuisson demandée.
      final more = item.copyWith(quantity: 3);
      expect(more.quantity, 3);
      expect(more.modifiers, hasLength(1));
      expect(more.modifiersLabel, 'Saignant');
    });

    test('modifiersKey est stable quel que soit l\'ordre de sélection', () {
      const a = SaleItem(
          productId: 'p1', productName: 'Steak', unitPrice: 5000,
          quantity: 1, modifiers: [_cuisson, _fromage]);
      const b = SaleItem(
          productId: 'p1', productName: 'Steak', unitPrice: 5000,
          quantity: 1, modifiers: [_fromage, _cuisson]);
      // Deux serveurs qui cochent les mêmes options dans un ordre différent
      // doivent produire une ligne fusionnable, pas deux lignes.
      expect(a.modifiersKey, b.modifiersKey);
    });

    test('des options différentes donnent des clés différentes', () {
      const saignant = SaleItem(
          productId: 'p1', productName: 'Steak', unitPrice: 5000,
          quantity: 1, modifiers: [_cuisson]);
      const nature = SaleItem(
          productId: 'p1', productName: 'Steak', unitPrice: 5000,
          quantity: 1);
      expect(saignant.modifiersKey == nature.modifiersKey, isFalse);
    });
  });

  group('RestaurantOrderService — matérialisation du prix', () {
    test('sans option, aucun customPrice n\'est posé', () {
      final item = RestaurantOrderService.buildItem(
        productId: 'p1', productName: 'Café',
        unitPrice: 500, priceBuy: 200,
      );
      // Poser un customPrice égal au prix normal déclencherait à tort
      // l'affichage « prix modifié » et l'alerte de marge.
      expect(item.customPrice, isNull);
      expect(item.subtotal, 500);
    });

    test('un supplément est intégré au prix de la ligne', () {
      final item = RestaurantOrderService.buildItem(
        productId: 'p1', productName: 'Burger',
        unitPrice: 3000, priceBuy: 1000,
        modifiers: const [_fromage],
      );
      expect(item.customPrice, 3500);
      expect(item.subtotal, 3500);
      expect(item.modifiersLabel, 'Fromage');
    });

    test('les impacts se cumulent, y compris négatifs', () {
      final item = RestaurantOrderService.buildItem(
        productId: 'p1', productName: 'Burger',
        unitPrice: 3000, priceBuy: 1000,
        quantity: 2,
        modifiers: const [_fromage, _sansSauce],
      );
      // 3000 + 500 - 200 = 3300, ×2 couverts
      expect(item.customPrice, 3300);
      expect(item.subtotal, 6600);
    });

    test('une remise ne peut pas rendre la ligne négative', () {
      final item = RestaurantOrderService.buildItem(
        productId: 'p1', productName: 'Supplément seul',
        unitPrice: 100, priceBuy: 0,
        modifiers: const [_sansSauce],
      );
      expect(item.customPrice, 0);
      expect(item.subtotal, 0);
    });

    test('partage : arrondi SUPÉRIEUR pour que la caisse tombe juste', () {
      // 10 000 ÷ 3 = 3333,33. Avec un arrondi bas, 3×3333 = 9999 → il
      // manquerait 1 F en caisse à chaque partage.
      final part = RestaurantOrderService.splitAmount(10000, 3);
      expect(part, 3334);
      expect(part * 3, greaterThanOrEqualTo(10000.0));
    });

    test('partage : 1 part renvoie le total intact', () {
      expect(RestaurantOrderService.splitAmount(7500, 1), 7500);
      // Une valeur absurde ne doit pas produire de division par zéro.
      expect(RestaurantOrderService.splitAmount(7500, 0), 7500);
    });

    test('partage : division exacte ne sur-facture pas', () {
      expect(RestaurantOrderService.splitAmount(9000, 3), 3000);
    });

    test('le total matérialisé est visible par un recalcul « naïf »', () {
      // Simule ce que font dashboard/exports/métriques : ils ignorent
      // `modifiers` et lisent `custom_price ?? unit_price`. Le total doit
      // rester juste — c'est tout l'intérêt de la matérialisation.
      final item = RestaurantOrderService.buildItem(
        productId: 'p1', productName: 'Burger',
        unitPrice: 3000, priceBuy: 1000, quantity: 2,
        modifiers: const [_fromage],
      );
      final naive = (item.customPrice ?? item.unitPrice) *
          item.quantity *
          (1 - item.discount / 100);
      expect(naive, item.subtotal);
      expect(naive, 7000);
    });
  });
}

// ── PR-4 : modificateurs et à emporter ─────────────────────────────────────
// Ajouté en fin de fichier pour garder les groupes PR-2/PR-3 intacts.
void _pr4Tests() {
  group('MenuModifier — portée et sérialisation', () {
    test('un groupe sans produit s\'applique à toute la carte', () {
      final global = MenuModifier(
        id: 'mm_1', shopId: 'shop_1', name: 'Cuisson',
        options: const [ModifierOption(name: 'Saignant')],
        createdAt: DateTime.utc(2026, 7, 19),
      );
      expect(global.appliesTo('prod_1'), isTrue);
      expect(global.appliesTo('prod_2'), isTrue);
    });

    test('un groupe lié ne s\'applique qu\'à son produit', () {
      final scoped = MenuModifier(
        id: 'mm_2', shopId: 'shop_1', productId: 'prod_1', name: 'Cuisson',
        options: const [ModifierOption(name: 'Saignant')],
        createdAt: DateTime.utc(2026, 7, 19),
      );
      expect(scoped.appliesTo('prod_1'), isTrue);
      expect(scoped.appliesTo('prod_2'), isFalse);
    });

    test('round-trip toMap → fromMap conserve options et impacts', () {
      final m = MenuModifier(
        id: 'mm_3', shopId: 'shop_1', productId: 'prod_9', name: 'Suppléments',
        options: const [
          ModifierOption(name: 'Fromage', priceImpact: 500),
          ModifierOption(name: 'Sans sauce', priceImpact: -200),
        ],
        createdAt: DateTime.utc(2026, 7, 19),
      );
      final back = MenuModifier.fromMap(m.toMap());
      expect(back.name, 'Suppléments');
      expect(back.productId, 'prod_9');
      expect(back.options, hasLength(2));
      expect(back.options[0].priceImpact, 500);
      expect(back.options[1].priceImpact, -200);
    });

    test('options absentes ou malformées → liste vide, pas de crash', () {
      // Le JSONB Supabase peut renvoyer null ou un scalaire sur une ligne
      // écrite à la main ; la page de config ne doit pas planter.
      final raw = {
        'id': 'mm_4', 'shop_id': 'shop_1', 'name': 'Vide',
        'options': null,
      };
      expect(MenuModifier.fromMap(raw).options, isEmpty);
    });
  });
}
