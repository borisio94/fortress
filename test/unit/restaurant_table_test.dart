// Tests unitaires de l'entité RestaurantTable (module restaurant, PR-1).
//
// Stratégie : entité pure (aucun Hive, aucun Supabase) → on couvre le
// contrat de sérialisation (toMap/fromMap, clés SQL, tolérance aux données
// legacy) et la sémantique de copyWith, qui est le point sensible : sans
// sentinelle, libérer une table (remettre covers/openedAt à null) serait
// impossible.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/config/restaurant_mode.dart';
import 'package:fortress/features/restaurant/domain/entities/restaurant_table.dart';

RestaurantTable _table({
  RestaurantTableStatus status = RestaurantTableStatus.libre,
  int? covers,
  DateTime? openedAt,
  String? currentOrderId,
}) =>
    RestaurantTable(
      id: 'rt_1',
      shopId: 'shop_1',
      number: 3,
      name: 'T3',
      capacity: 6,
      status: status,
      covers: covers,
      openedAt: openedAt,
      currentOrderId: currentOrderId,
      createdAt: DateTime.utc(2026, 7, 19, 10, 30),
    );

void main() {
  group('RestaurantTableStatus — clés persistées', () {
    test('les clés SQL sont sans accent et stables', () {
      expect(RestaurantTableStatus.libre.key, 'libre');
      expect(RestaurantTableStatus.occupee.key, 'occupee');
      expect(RestaurantTableStatus.addition.key, 'addition');
      expect(RestaurantTableStatus.reservee.key, 'reservee');
    });

    test('les clés couvrent exactement le CHECK SQL de hotfix_137', () {
      // Si ce test casse, la contrainte CHECK côté Postgres rejettera
      // l'upsert : les deux listes DOIVENT rester alignées.
      const sqlCheck = {'libre', 'occupee', 'addition', 'reservee'};
      expect(RestaurantTableStatus.values.map((s) => s.key).toSet(), sqlCheck);
    });

    test('fromKey retombe sur libre pour une valeur inconnue ou nulle', () {
      expect(RestaurantTableStatusX.fromKey('occupee'),
          RestaurantTableStatus.occupee);
      expect(RestaurantTableStatusX.fromKey('n_importe_quoi'),
          RestaurantTableStatus.libre);
      expect(RestaurantTableStatusX.fromKey(null),
          RestaurantTableStatus.libre);
    });
  });

  group('RestaurantTable — sérialisation', () {
    test('toMap écrit les clés SQL attendues + schema_version', () {
      final map = _table(
        status: RestaurantTableStatus.occupee,
        covers: 4,
        openedAt: DateTime.utc(2026, 7, 19, 12),
      ).toMap();

      expect(map['schema_version'], RestaurantTable.currentSchemaVersion);
      expect(map['id'], 'rt_1');
      expect(map['shop_id'], 'shop_1');
      expect(map['number'], 3);
      expect(map['capacity'], 6);
      expect(map['status'], 'occupee');
      expect(map['covers'], 4);
      // Les dates partent en ISO UTC (comparabilité côté Postgres).
      expect(map['opened_at'], '2026-07-19T12:00:00.000Z');
    });

    test('round-trip toMap → fromMap conserve les champs', () {
      final original = _table(
        status: RestaurantTableStatus.addition,
        covers: 2,
        openedAt: DateTime.utc(2026, 7, 19, 12),
        currentOrderId: 'order_42',
      );
      final restored = RestaurantTable.fromMap(original.toMap());

      expect(restored.id, original.id);
      expect(restored.shopId, original.shopId);
      expect(restored.number, original.number);
      expect(restored.name, original.name);
      expect(restored.capacity, original.capacity);
      expect(restored.status, original.status);
      expect(restored.covers, original.covers);
      expect(restored.currentOrderId, 'order_42');
      expect(restored.openedAt?.toUtc(), original.openedAt?.toUtc());
    });

    test('fromMap tolère une ligne legacy minimale', () {
      // Cas réel : ligne écrite par une version antérieure, ou row Supabase
      // dont les colonnes optionnelles sont NULL. Ne doit pas throw.
      final restored = RestaurantTable.fromMap({
        'id': 'rt_legacy',
        'shop_id': 'shop_1',
        'name': 'T9',
      });

      expect(restored.id, 'rt_legacy');
      expect(restored.number, 0);
      expect(restored.capacity, 4, reason: 'défaut métier');
      expect(restored.status, RestaurantTableStatus.libre);
      expect(restored.covers, isNull);
      expect(restored.isFree, isTrue);
    });
  });

  group('RestaurantTable — copyWith', () {
    test('un champ non fourni est conservé', () {
      final t = _table(status: RestaurantTableStatus.occupee, covers: 4);
      final renamed = t.copyWith(name: 'Terrasse 1');

      expect(renamed.name, 'Terrasse 1');
      expect(renamed.covers, 4, reason: 'non fourni → conservé');
      expect(renamed.status, RestaurantTableStatus.occupee);
    });

    test('un champ explicitement mis à null est bien effacé', () {
      // C'est LE cas qui casserait sans la sentinelle `_unset` : libérer
      // une table doit remettre covers/openedAt/currentOrderId à null.
      final occupied = _table(
        status: RestaurantTableStatus.occupee,
        covers: 4,
        openedAt: DateTime.utc(2026, 7, 19, 12),
        currentOrderId: 'order_42',
      );
      final freed = occupied.copyWith(
        status: RestaurantTableStatus.libre,
        covers: null,
        openedAt: null,
        currentOrderId: null,
      );

      expect(freed.status, RestaurantTableStatus.libre);
      expect(freed.covers, isNull);
      expect(freed.openedAt, isNull);
      expect(freed.currentOrderId, isNull);
      expect(freed.isFree, isTrue);
      // L'identité et la configuration de la table survivent au service.
      expect(freed.id, occupied.id);
      expect(freed.capacity, 6);
    });
  });

  group('Libération de table après encaissement', () {
    test('release efface tout le contexte de service', () {
      // Reproduit ce que fait RestaurantTableService.release. Le point
      // critique est `currentOrderId` : sans sa remise à null, la table
      // rouvrirait sur la commande déjà encaissée au client suivant.
      final occupied = _table(
        status: RestaurantTableStatus.addition,
        covers: 4,
        openedAt: DateTime.utc(2026, 7, 19, 12),
        currentOrderId: 'order_42',
      );
      final freed = occupied.copyWith(
        status: RestaurantTableStatus.libre,
        covers: null,
        currentOrderId: null,
        openedAt: null,
        reservationTime: null,
        reservationName: null,
      );

      expect(freed.status, RestaurantTableStatus.libre);
      expect(freed.currentOrderId, isNull);
      expect(freed.covers, isNull);
      expect(freed.openedAt, isNull);
      // La table elle-même survit : nom, numéro et capacité sont de la
      // configuration, pas du service.
      expect(freed.name, 'T3');
      expect(freed.number, 3);
      expect(freed.capacity, 6);
    });
  });

  group('restaurant_mode — activation du module', () {
    test('seuls les secteurs de restauration activent le module', () {
      expect(isRestaurantSector('restaurant'), isTrue);
      expect(isRestaurantSector('fastfood'), isTrue);
      expect(isRestaurantSector('mixed'), isTrue);
      // Non-régression du mode boutique : aucun de ces secteurs ne doit
      // faire apparaître le plan de salle.
      expect(isRestaurantSector('retail'), isFalse);
      expect(isRestaurantSector('ecommerce'), isFalse);
      expect(isRestaurantSector('supermarche'), isFalse);
      expect(isRestaurantSector(''), isFalse);
      expect(isRestaurantSector(null), isFalse);
    });

    test('establishmentLabel couvre les secteurs legacy', () {
      expect(establishmentLabel('retail'), 'Boutique');
      expect(establishmentLabel('restaurant'), 'Restaurant / Café');
      expect(establishmentLabel('supermarche'), 'Supermarché');
      // Valeur inconnue → renvoyée telle quelle plutôt que vide.
      expect(establishmentLabel('inconnu'), 'inconnu');
    });

    test('les clés proposées dans Paramètres sont uniques', () {
      final keys = kEstablishmentTypes.map((t) => t.key).toList();
      expect(keys.toSet().length, keys.length);
    });
  });
}
