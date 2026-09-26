// Les actions sur une table du plan de salle (`tableActionsFor`) — sorties
// de la page le 26/09/2026 (lot « classes géantes ») : la page vit sous
// `AppScaffold` et ne se monte pas en test.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/restaurant/domain/entities/restaurant_table.dart';
import 'package:fortress/features/restaurant/domain/table_actions.dart';

RestaurantTable table(RestaurantTableStatus status, {DateTime? reservedAt}) =>
    RestaurantTable(
      id: 't1',
      shopId: 'shop1',
      number: 1,
      name: 'Table 1',
      createdAt: DateTime(2026),
      status: status,
      reservationTime: reservedAt,
    );

void main() {
  const inService = [
    TableAction.bill,
    TableAction.tabs,
    TableAction.covers,
    TableAction.release,
  ];

  test('libre : réserver ; supprimer seulement avec le droit de composer', () {
    final t = table(RestaurantTableStatus.libre);
    expect(tableActionsFor(t, canManageRoom: false), [TableAction.reserve]);
    expect(tableActionsFor(t, canManageRoom: true),
        [TableAction.reserve, TableAction.delete]);
  });

  test('occupée : addition, comptes, couverts, libérer — jamais supprimer',
      () {
    final t = table(RestaurantTableStatus.occupee);
    expect(tableActionsFor(t, canManageRoom: true), inService);
    expect(tableActionsFor(t, canManageRoom: false), inService);
  });

  test('addition demandée : les mêmes actions qu’en service', () {
    expect(
        tableActionsFor(table(RestaurantTableStatus.addition),
            canManageRoom: true),
        inService);
  });

  test('réservée pour plus tard : seulement annuler la réservation', () {
    final t = table(RestaurantTableStatus.reservee,
        reservedAt: DateTime.now().add(const Duration(hours: 2)));
    expect(tableActionsFor(t, canManageRoom: true),
        [TableAction.cancelReservation]);
  });

  test('réservée, heure passée mais dans la courtoisie : encore retenue', () {
    final t = table(RestaurantTableStatus.reservee,
        reservedAt: DateTime.now().subtract(const Duration(minutes: 10)));
    expect(tableActionsFor(t, canManageRoom: true),
        [TableAction.cancelReservation]);
  });

  test('réservation périmée : la table est libre (ni addition ni couverts)',
      () {
    final t = table(RestaurantTableStatus.reservee,
        reservedAt: DateTime.now().subtract(const Duration(hours: 2)));
    expect(tableActionsFor(t, canManageRoom: true),
        [TableAction.reserve, TableAction.delete]);
  });

  test('réservée sans heure : comptée comme libre', () {
    final t = table(RestaurantTableStatus.reservee);
    expect(tableActionsFor(t, canManageRoom: false), [TableAction.reserve]);
  });
}
