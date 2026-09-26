// La date d'état SUIT L'ÉTAT, pas la commande (hotfix_183, 25/09/2026).
//
// Le test qui compte le plus du lot horodatage : à chaque transition réelle
// (`RestaurantOrderService` → `_patchOrder` → Hive), `service_state_at` est
// RÉÉCRITE — le chronomètre repart de zéro dans le nouvel état. Si le compteur
// continuait après « Prête », tout le lot serait à refaire.
//
// Chemin RÉEL, pas une fonction isolée : Hive sur un dossier temporaire, la
// commande relue par la vraie datasource, l'écriture distante mise en file
// hors ligne comme sur un appareil sans réseau.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:fortress/core/services/restaurant_order_service.dart';
import 'package:fortress/core/storage/hive_boxes.dart';
import 'package:fortress/features/caisse/data/repositories/sale_local_datasource.dart';

void main() {
  late Directory tmp;
  final ds = SaleLocalDatasource();

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('fortress_state_transition');
    Hive.init(tmp.path);
    await Hive.openBox<Map>(HiveBoxes.orders);
    await Hive.openBox<Map>(HiveBoxes.offlineQueue);
  });

  tearDownAll(() async {
    await Hive.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// Une commande en salle, déjà en préparation depuis une heure.
  const t0 = '2026-09-25T18:00:00.000Z';
  Map<String, dynamic> inKitchen(String id) => {
        'id': id,
        'shop_id': 'shop1',
        'status': 'scheduled',
        'payment_method': 'cash',
        'created_at': '2026-09-25T17:30:00.000Z',
        'items': const [],
        'order_type': 'dine_in',
        'sent_to_kitchen': true,
        'kitchen_ready': false,
        'served': false,
        'finished': false,
        'service_state_at': t0,
      };

  DateTime stateAt(String id) => DateTime.parse(
      HiveBoxes.ordersBox.get(id)!['service_state_at'] as String);

  test('« Prête » : la date d\'état est RÉÉCRITE — le chronomètre repart',
      () async {
    await HiveBoxes.ordersBox.put('c1', inKitchen('c1'));
    final avant = ds.getOrderById('c1')!;
    expect(avant.serviceStateAt, DateTime.parse(t0));

    final tap = DateTime.now().toUtc();
    await RestaurantOrderService.markKitchenReady(avant);

    final raw = HiveBoxes.ordersBox.get('c1')!;
    expect(raw['kitchen_ready'], isTrue);
    final apres = stateAt('c1');
    expect(apres, isNot(DateTime.parse(t0)),
        reason: 'si la date ne bouge pas, le compteur CONTINUE — lot à refaire');
    expect(apres.difference(tap).inSeconds.abs(), lessThan(5),
        reason: 'la nouvelle date est l\'instant de la transition');

    // Relue par la vraie datasource : c'est ce que lit la carte.
    expect(ds.getOrderById('c1')!.serviceStateAt, apres);
  });

  test('chaque transition redate : Prête puis Servie', () async {
    await HiveBoxes.ordersBox.put('c2', inKitchen('c2'));
    await RestaurantOrderService.markKitchenReady(ds.getOrderById('c2')!);
    final pret = stateAt('c2');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await RestaurantOrderService.markServed(ds.getOrderById('c2')!);
    final servi = stateAt('c2');
    expect(servi.isAfter(pret), isTrue);
  });

  test('l\'écriture distante emporte la MÊME date que Hive', () async {
    await HiveBoxes.ordersBox.put('c4', inKitchen('c4'));
    await RestaurantOrderService.markKitchenReady(ds.getOrderById('c4')!);
    final queued = HiveBoxes.offlineQueueBox.values
        .map((v) => Map<String, dynamic>.from(v as Map))
        .where((op) =>
            op['table'] == 'orders' &&
            (op['match'] as Map?)?['id'] == 'c4')
        .toList();
    expect(queued, isNotEmpty);
    final data = Map<String, dynamic>.from(queued.last['data'] as Map);
    expect(data['kitchen_ready'], isTrue);
    expect(data['service_state_at'],
        HiveBoxes.ordersBox.get('c4')!['service_state_at'],
        reason: 'Hive et Supabase ne doivent pas diverger');
  });
}
