// Lot horodatage (hotfix_183, 25/09/2026) — l'instant d'entrée dans l'état de
// service, sa datation, sa lecture, et les seuils de retard.
//
// Hive est initialisé sur un dossier temporaire réel, comme
// `order_hive_mapping_test` : la lecture passe par le vrai mapping.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:fortress/core/storage/hive_boxes.dart';
import 'package:fortress/features/caisse/data/repositories/sale_local_datasource.dart';
import 'package:fortress/features/caisse/domain/entities/sale.dart';
import 'package:fortress/features/restaurant/domain/service_tabs.dart';
import 'package:fortress/features/restaurant/domain/service_wait.dart';
import 'package:fortress/features/shop_selector/domain/entities/shop_summary.dart';

void main() {
  final now = DateTime.utc(2026, 9, 25, 20, 0);

  group('serviceStateStamp — UNE règle : toucher un drapeau, c\'est dater', () {
    for (final flag in kServiceFlagKeys) {
      test('« $flag » date le patch', () {
        final out = serviceStateStamp({flag: true}, now);
        expect(out[kServiceStateAtKey], now.toIso8601String());
        expect(out[flag], isTrue);
      });
    }

    test('l\'encaissement date aussi (il force served et finished)', () {
      final out = serviceStateStamp(
          {'payment_method': 'cash', 'served': true, 'finished': true}, now);
      expect(out[kServiceStateAtKey], isNotNull);
    });

    test('un patch sans drapeau ne date PAS — l\'attente ne repart pas à zéro',
        () {
      for (final patch in [
        {'payment_method': 'cash'},
        {'cancellation_reason': 'client parti'},
      ]) {
        expect(serviceStateStamp(patch, now), same(patch));
      }
    });

    test('la date est en UTC ISO — ce que Postgres attend', () {
      final local = DateTime(2026, 9, 25, 21, 0); // heure locale
      final out = serviceStateStamp({'served': true}, local);
      expect((out[kServiceStateAtKey] as String).endsWith('Z'), isTrue);
    });
  });

  group('serviceWait — l\'attente dans l\'état, jamais l\'âge de la commande',
      () {
    Sale order({DateTime? since, DateTime? created}) => Sale(
          shopId: 's',
          items: const [],
          paymentMethod: PaymentMethod.cash,
          createdAt: created ?? now.subtract(const Duration(hours: 9)),
          serviceStateAt: since,
        );

    test('sans date d\'état : AUCUN chronomètre, même sur une vieille commande',
        () {
      expect(serviceWait(order(), now), isNull);
    });

    test('avec date : le temps depuis l\'entrée dans l\'état', () {
      final o = order(since: now.subtract(const Duration(minutes: 24)));
      expect(serviceWait(o, now), const Duration(minutes: 24));
    });

    test('horloge décalée : jamais négatif', () {
      final o = order(since: now.add(const Duration(minutes: 3)));
      expect(serviceWait(o, now), Duration.zero);
    });
  });

  group('seuils de retard', () {
    test('défauts : 5 / 20 / 5 — ceux du SQL', () {
      expect(kServiceLateSendDefault, 5);
      expect(kServiceLateKitchenDefault, 20);
      expect(kServiceLatePassDefault, 5);
      const shop = ShopSummary(
          id: 's',
          name: 'Resto',
          currency: 'XAF',
          country: 'CM',
          sector: 'restaurant');
      expect(shop.serviceLateSendMin, 5);
      expect(shop.serviceLateKitchenMin, 20);
      expect(shop.serviceLatePassMin, 5);
    });

    test('trois rangs seulement ont un seuil', () {
      int? t(ServiceTab tab) =>
          lateThresholdFor(tab, sendMin: 5, kitchenMin: 20, passMin: 7);
      expect(t(ServiceTab.aEnvoyer), 5);
      expect(t(ServiceTab.enPreparation), 20);
      expect(t(ServiceTab.aServir), 7);
      for (final tab in [
        ServiceTab.aTerminer,
        ServiceTab.aEncaisser,
        ServiceTab.encaissees,
        ServiceTab.sansSuite,
        ServiceTab.toutes,
      ]) {
        expect(t(tab), isNull, reason: tab.name);
      }
    });

    test('en retard au seuil, pas avant ; jamais sans date', () {
      Sale inKitchen(Duration since) => Sale(
            shopId: 's',
            items: const [],
            paymentMethod: PaymentMethod.cash,
            createdAt: now,
            status: SaleStatus.scheduled,
            sentToKitchen: true,
            serviceStateAt: since == Duration.zero ? null : now.subtract(since),
          );
      bool late(Sale o) =>
          isServiceLate(o, now, sendMin: 5, kitchenMin: 20, passMin: 5);
      expect(late(inKitchen(const Duration(minutes: 19))), isFalse);
      expect(late(inKitchen(const Duration(minutes: 20))), isTrue);
      expect(late(inKitchen(Duration.zero)), isFalse,
          reason: 'sans date d\'état, jamais « en retard »');
    });
  });

  group('lecture Hive — nouvelles et ANCIENNES commandes', () {
    late Directory tmp;
    final ds = SaleLocalDatasource();

    setUpAll(() async {
      tmp = Directory.systemTemp.createTempSync('fortress_service_wait_test');
      Hive.init(tmp.path);
      await Hive.openBox<Map>(HiveBoxes.orders);
    });

    tearDownAll(() async {
      await Hive.close();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    Map<String, dynamic> orderMap(String id) => {
          'id': id,
          'shop_id': 'shop1',
          'status': 'scheduled',
          'payment_method': 'cash',
          'created_at': '2026-09-25T08:00:00.000Z',
          'items': const [],
          'order_type': 'dine_in',
          'sent_to_kitchen': true,
        };

    test('nouvelle commande : service_state_at relu', () async {
      await HiveBoxes.ordersBox.put(
          'n1', orderMap('n1')..['service_state_at'] = '2026-09-25T19:36:00.000Z');
      final sale = ds.getOrderById('n1');
      expect(sale!.serviceStateAt, DateTime.parse('2026-09-25T19:36:00.000Z'));
    });

    test('commande d\'HIER, sans la clé : relue sans planter, date à null',
        () async {
      await HiveBoxes.ordersBox.put('o1', orderMap('o1'));
      final sale = ds.getOrderById('o1');
      expect(sale, isNotNull);
      expect(sale!.serviceStateAt, isNull);
      expect(serviceWait(sale, now), isNull);
    });

    test('valeur NULL explicite (colonne présente, ligne ancienne) : idem',
        () async {
      await HiveBoxes.ordersBox
          .put('o2', orderMap('o2')..['service_state_at'] = null);
      expect(ds.getOrderById('o2')!.serviceStateAt, isNull);
    });
  });

  group('aucun chemin n\'oublie la clé (source)', () {
    test('les 4 écritures de la datasource et les 2 reconstructions', () {
      final ds = File(
              'lib/features/caisse/data/repositories/sale_local_datasource.dart')
          .readAsStringSync();
      expect("'service_state_at': order.serviceStateAt".allMatches(ds).length,
          4);
      final db = File('lib/core/database/app_database.dart').readAsStringSync();
      expect("'service_state_at': row['service_state_at']".allMatches(db).length,
          2,
          reason: 'syncOrders ET _onOrderChange — le piège connu');
    });
  });
}
