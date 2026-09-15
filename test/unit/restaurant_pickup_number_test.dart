import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/services/restaurant_order_service.dart';

/// Numéros de retrait des commandes à emporter — partie pure, sans Hive.
///
/// Le repère doit être court et RÉUTILISABLE : deux commandes retirées puis
/// une troisième prise doit reprendre « R1 », pas « R3 ». Un service qui
/// tourne toute la journée finirait sinon à crier « R247 » au comptoir.
void main() {
  group('RestaurantOrderService.firstFreePickup', () {
    test('rend R1 quand aucune commande n\'est ouverte', () {
      expect(RestaurantOrderService.firstFreePickup(const []), 'R1');
    });

    test('saute les numéros déjà pris', () {
      expect(
          RestaurantOrderService.firstFreePickup(const ['R1', 'R2']), 'R3');
    });

    test('reprend le premier TROU, pas la suite du compteur', () {
      // R2 est parti avec son client : son numéro redevient disponible.
      expect(
          RestaurantOrderService.firstFreePickup(const ['R1', 'R3']), 'R2');
    });

    test('ignore la casse — un « r3 » saisi à la main reste pris', () {
      expect(
          RestaurantOrderService.firstFreePickup(const ['R1', 'r2', 'R3']),
          'R4');
    });

    test('ignore les libellés vides et les espaces', () {
      expect(
          RestaurantOrderService.firstFreePickup(const ['', '  ', ' R1 ']),
          'R2');
    });

    test('les libellés nommés ne consomment aucun numéro', () {
      // Un compte nommé « M. Ali » n'occupe pas R1 : les deux systèmes de
      // repère cohabitent sur le même champ.
      expect(
          RestaurantOrderService.firstFreePickup(const ['M. Ali', 'Awa']),
          'R1');
    });

    test('rend quand même un repère au-delà de la borne', () {
      final all = [for (var n = 1; n <= 999; n++) 'R$n'];
      final res = RestaurantOrderService.firstFreePickup(all);
      expect(res.startsWith('R'), isTrue);
      expect(all.contains(res), isFalse);
    });
  });
}
