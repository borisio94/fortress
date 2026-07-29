// Tests unitaires des comptes de service (plan de salle — Lot 3).
//
// Un compte n'est pas une entité stockée : c'est le regroupement des commandes
// ouvertes qui partagent `tableId` + `tabLabel`. Les deux règles qui portent
// tout le reste sont pures et vérifiées ici :
//
//   * `groupByLabel` — deux clients à la même table ne doivent JAMAIS voir
//     leurs commandes fondues dans la même addition ;
//   * `uniqueLabel` — transférer « Compte 1 » vers une table qui a déjà son
//     « Compte 1 » fusionnerait deux additions étrangères, et le serveur ne
//     s'en apercevrait qu'au moment de faire payer.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/services/restaurant_tab_service.dart';
import 'package:fortress/features/caisse/domain/entities/sale.dart';
import 'package:fortress/features/caisse/domain/entities/sale_item.dart';

Sale _order({
  required String id,
  String? tabLabel,
  String? tableId = 'rt_5',
  int minute = 0,
  double price = 1000,
  int qty = 1,
}) =>
    Sale(
      id: id,
      shopId: 'shop_1',
      items: [
        SaleItem(
          productId: 'p_1',
          productName: 'Ndolé',
          unitPrice: price,
          quantity: qty,
        ),
      ],
      createdAt: DateTime(2026, 7, 28, 12, minute),
      paymentMethod: PaymentMethod.cash,
      tableId: tableId,
      tabLabel: tabLabel,
    );

void main() {
  _newTabTests();
  group('Regroupement par compte', () {
    test('deux comptes distincts à la même table restent séparés', () {
      // Le cas qui motive tout le lot : deux clients assis ensemble.
      final tabs = RestaurantTabService.groupByLabel([
        _order(id: 'o1', tabLabel: 'Compte 1', minute: 0),
        _order(id: 'o2', tabLabel: 'Compte 2', minute: 5),
        _order(id: 'o3', tabLabel: 'Compte 1', minute: 10),
      ], 'rt_5');

      expect(tabs.length, 2);
      expect(tabs.first.label, 'Compte 1');
      expect(tabs.first.orderCount, 2);
      expect(tabs.last.label, 'Compte 2');
      expect(tabs.last.orderCount, 1);
    });

    test('les commandes sans libellé forment UN seul compte', () {
      // Sinon une table dont personne n'a nommé les comptes afficherait
      // autant d'additions que de tournées.
      final tabs = RestaurantTabService.groupByLabel([
        _order(id: 'o1', minute: 0),
        _order(id: 'o2', minute: 5),
      ], 'rt_5');

      expect(tabs.length, 1);
      expect(tabs.single.isUnnamed, isTrue);
      expect(tabs.single.displayLabel, 'Sans compte');
      expect(tabs.single.orderCount, 2);
    });

    test('un libellé fait d\'espaces compte comme absent', () {
      final tabs = RestaurantTabService.groupByLabel([
        _order(id: 'o1', tabLabel: '   '),
        _order(id: 'o2'),
      ], 'rt_5');
      expect(tabs.length, 1);
      expect(tabs.single.isUnnamed, isTrue);
    });

    test('les comptes nommés passent avant « Sans compte »', () {
      final tabs = RestaurantTabService.groupByLabel([
        _order(id: 'o1', minute: 0),
        _order(id: 'o2', tabLabel: 'M. Ali', minute: 30),
      ], 'rt_5');
      expect(tabs.first.label, 'M. Ali');
      expect(tabs.last.isUnnamed, isTrue);
    });

    test('à libellés nommés, le plus ancien arrive en tête', () {
      final tabs = RestaurantTabService.groupByLabel([
        _order(id: 'o1', tabLabel: 'B', minute: 30),
        _order(id: 'o2', tabLabel: 'A', minute: 5),
      ], 'rt_5');
      expect(tabs.first.label, 'A');
    });

    test('total et nombre d\'articles cumulent les tournées', () {
      final tabs = RestaurantTabService.groupByLabel([
        _order(id: 'o1', tabLabel: 'C1', price: 2000, qty: 2),
        _order(id: 'o2', tabLabel: 'C1', price: 1000, qty: 3),
      ], 'rt_5');
      final tab = tabs.single;
      expect(tab.total, 7000);
      expect(tab.itemCount, 5);
    });

    test('aucune commande → aucun compte', () {
      expect(RestaurantTabService.groupByLabel(const [], 'rt_5'), isEmpty);
    });
  });

  group('Libellé unique à la destination', () {
    test('un libellé libre est conservé tel quel', () {
      expect(RestaurantTabService.uniqueLabel('Compte 1', {'Compte 2'}),
          'Compte 1');
    });

    test('un libellé déjà pris est suffixé', () {
      // Sans ça, le transfert fusionnerait deux additions de clients
      // différents qui portent le même nom générique.
      expect(RestaurantTabService.uniqueLabel('Compte 1', {'Compte 1'}),
          'Compte 1 (2)');
    });

    test('le suffixe s\'incrémente tant que c\'est pris', () {
      expect(
          RestaurantTabService.uniqueLabel(
              'Compte 1', {'Compte 1', 'Compte 1 (2)', 'Compte 1 (3)'}),
          'Compte 1 (4)');
    });

    test('un libellé vide n\'est jamais suffixé', () {
      // « Sans compte » n'est pas un nom : deux lots sans libellé PEUVENT
      // se rejoindre, c'est le comportement attendu.
      expect(RestaurantTabService.uniqueLabel('', {''}), '');
    });
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Compte fraîchement ouvert (écran de service)
//
// Un compte n'est pas une entité stockée : c'est le regroupement des commandes
// qui partagent un libellé. Un compte qu'on vient d'ouvrir n'a donc AUCUNE
// commande — `groupByLabel` ne le renvoie pas, et l'écran n'affichait aucune
// puce : « Ouvrir » semblait sans effet alors que le compte était sélectionné.
// ─────────────────────────────────────────────────────────────────────────────
void _newTabTests() {
  /// Reproduit la règle d'affichage de l'écran de service : les comptes qui
  /// portent des commandes, plus celui qui vient d'être ouvert.
  List<String> visibleLabels(List<RestaurantTab> tabs, String current) {
    final labels = [for (final t in tabs.where((t) => !t.isUnnamed)) t.label];
    if (current.isNotEmpty && !labels.contains(current)) labels.add(current);
    return labels;
  }

  group('Puces de comptes affichées', () {
    test('un compte ouvert SANS commande reste visible', () {
      // Le bug : aucune commande → aucun tab → aucune puce → écran figé.
      expect(visibleLabels(const [], 'Compte 1'), ['Compte 1']);
    });

    test('pas de doublon quand le compte reçoit sa première commande', () {
      final tabs = RestaurantTabService.groupByLabel(
          [_order(id: 'o1', tabLabel: 'Compte 1')], 'rt_1');
      expect(visibleLabels(tabs, 'Compte 1'), ['Compte 1']);
    });

    test('le compte principal n\'est jamais dupliqué', () {
      // Il a sa propre puce, en dur : le libellé vide ne doit rien ajouter.
      final tabs = RestaurantTabService.groupByLabel([_order(id: 'o1')], 'rt_1');
      expect(visibleLabels(tabs, ''), isEmpty);
    });

    test('les comptes existants restent listés', () {
      final tabs = RestaurantTabService.groupByLabel([
        _order(id: 'o1', tabLabel: 'Compte 1'),
        _order(id: 'o2', tabLabel: 'M. Ali'),
      ], 'rt_1');
      expect(visibleLabels(tabs, 'Compte 2').length, 3);
      expect(visibleLabels(tabs, 'Compte 2'), contains('Compte 2'));
    });
  });
}
