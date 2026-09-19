// Test d'intégration léger du mapping commande Hive → Sale (P0 Phase 1).
//
// Vérifie que les 4 champs ajoutés au hiveMap de syncOrders / _onOrderChange
// (idempotency_key, deleted_at, deleted_by, delete_reason) sont bien RELUS
// par la datasource — c'est-à-dire que l'écriture (app_database) et la
// lecture (_mapToSaleWithStatus) sont alignées dans les deux directions.
//
// Hive est initialisé sur un dossier temporaire réel (la suite ne mocke pas
// Supabase ; getOrderById ne touche que Hive + le mapping pur).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:fortress/core/storage/hive_boxes.dart';
import 'package:fortress/features/caisse/data/repositories/sale_local_datasource.dart';

void main() {
  late Directory tmp;
  final ds = SaleLocalDatasource();

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('fortress_orders_test');
    Hive.init(tmp.path);
    await Hive.openBox<Map>(HiveBoxes.orders);
  });

  tearDownAll(() async {
    await Hive.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// Map Hive non supprimée, telle que produite par syncOrders après le fix.
  Map<String, dynamic> orderMap(String id) => {
        'id': id,
        'shop_id': 'shop1',
        'status': 'completed',
        'payment_method': 'cash',
        'created_at': '2024-01-01T00:00:00.000Z',
        'items': const [],
        'idempotency_key': 'idem-$id',
      };

  test('idempotency_key relu depuis Hive (GF-1)', () async {
    await HiveBoxes.ordersBox.put('o1', orderMap('o1'));
    final sale = ds.getOrderById('o1');
    expect(sale, isNotNull);
    expect(sale!.idempotencyKey, 'idem-o1');
  });

  test('soft-delete : deleted_at/by/reason relus (includeDeleted)', () async {
    final map = orderMap('o2')
      ..['deleted_at'] = '2024-02-02T10:00:00.000Z'
      ..['deleted_by'] = 'user-42'
      ..['delete_reason'] = 'erreur de saisie';
    await HiveBoxes.ordersBox.put('o2', map);

    // Masquée par défaut (symétrie RLS / getOrders).
    expect(ds.getOrderById('o2'), isNull);

    // Champs préservés quand on inclut les supprimées.
    final sale = ds.getOrderById('o2', includeDeleted: true);
    expect(sale, isNotNull);
    expect(sale!.isDeleted, isTrue);
    expect(sale.deletedBy, 'user-42');
    expect(sale.deleteReason, 'erreur de saisie');
    expect(sale.deletedAt, DateTime.parse('2024-02-02T10:00:00.000Z'));
  });

  test('legacy : commande sans les 4 champs → valeurs nulles tolérées',
      () async {
    final map = orderMap('o3')..remove('idempotency_key');
    await HiveBoxes.ordersBox.put('o3', map);
    final sale = ds.getOrderById('o3');
    expect(sale, isNotNull);
    expect(sale!.idempotencyKey, isNull);
    expect(sale.isDeleted, isFalse);
  });
}
