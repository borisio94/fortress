import 'package:flutter/foundation.dart' show debugPrint;
import 'package:hive_flutter/hive_flutter.dart';

import '../../features/restaurant/domain/entities/restaurant_table.dart';
import '../database/app_database.dart';
import '../storage/hive_boxes.dart';

/// Service Hive-first du plan de salle. Toute mutation est :
///   1. écrite IMMÉDIATEMENT dans Hive (offline-first),
///   2. poussée en arrière-plan vers Supabase (file offline si hors ligne),
///   3. notifiée aux listeners `AppDatabase` pour rafraîchir l'UI.
///
/// Les ids sont générés CÔTÉ CLIENT (`rt_` + microsecondes) pour qu'une table
/// créée hors ligne soit immédiatement utilisable et que Hive ↔ Supabase
/// partagent la même clé (convention delivery_zones / partner_ledger_entries).
class RestaurantTableService {
  RestaurantTableService._();

  static Box<Map> _raw() => HiveBoxes.restaurantTablesBox;

  static String _tableId() => 'rt_${DateTime.now().microsecondsSinceEpoch}';

  /// Tables de la boutique, triées par numéro croissant.
  static List<RestaurantTable> tablesForShop(String shopId) {
    try {
      final list = <RestaurantTable>[];
      for (final raw in _raw().values) {
        if (raw['shop_id']?.toString() != shopId) continue;
        try {
          list.add(RestaurantTable.fromMap(Map<String, dynamic>.from(raw)));
        } catch (_) {/* ligne corrompue : ignorée, pas de crash de la page */}
      }
      list.sort((a, b) => a.number.compareTo(b.number));
      return list;
    } catch (e) {
      debugPrint('[Restaurant] tablesForShop err: $e');
      return [];
    }
  }

  static RestaurantTable? tableById(String id) {
    try {
      final raw = _raw().get(id);
      if (raw == null) return null;
      return RestaurantTable.fromMap(Map<String, dynamic>.from(raw));
    } catch (e) {
      debugPrint('[Restaurant] tableById err: $e');
      return null;
    }
  }

  /// Premier numéro de table libre pour cette boutique.
  ///
  /// Comble les trous : après suppression de T2 dans T1·T2·T3, la prochaine
  /// création reprend le 2 plutôt que de partir à 4. Évite aussi la violation
  /// de l'index unique `(shop_id, number)` quand on recrée après suppression.
  static int nextNumber(String shopId) {
    final used = tablesForShop(shopId).map((t) => t.number).toSet();
    var n = 1;
    while (used.contains(n)) {
      n++;
    }
    return n;
  }

  static Future<RestaurantTable> addTable({
    required String shopId,
    required String name,
    int capacity = 4,
    int? number,
  }) async {
    final table = RestaurantTable(
      id: _tableId(),
      shopId: shopId,
      number: number ?? nextNumber(shopId),
      name: name.trim(),
      capacity: capacity,
      createdAt: DateTime.now(),
    );
    await _persist(table);
    return table;
  }

  /// Écrit une table (création OU mise à jour). Hive d'abord, puis push.
  static Future<void> save(RestaurantTable table) => _persist(table);

  static Future<void> _persist(RestaurantTable table) async {
    final map = table.toMap();
    try {
      await _raw().put(table.id, map);
    } catch (e) {
      debugPrint('[Restaurant] save Hive err: $e');
    }
    AppDatabase.bgUpsert('restaurant_tables', map);
    AppDatabase.notifyListeners('restaurant_tables', table.shopId);
  }

  /// Ouvre le service sur une table libre : statut `occupee`, couverts posés
  /// et horodatage d'ouverture (base du calcul de durée de repas en PR-3).
  static Future<RestaurantTable> openService({
    required RestaurantTable table,
    required int covers,
  }) async {
    final opened = table.copyWith(
      status: RestaurantTableStatus.occupee,
      covers: covers,
      openedAt: DateTime.now(),
    );
    await _persist(opened);
    return opened;
  }

  /// Libère la table : remet tout le contexte de service à null.
  ///
  /// `currentOrderId` est explicitement remis à null — sans ça, la table
  /// rouvrirait sur la commande du service précédent au prochain client.
  static Future<RestaurantTable> release(RestaurantTable table) async {
    final freed = table.copyWith(
      status: RestaurantTableStatus.libre,
      covers: null,
      currentOrderId: null,
      openedAt: null,
      reservationTime: null,
      reservationName: null,
    );
    await _persist(freed);
    return freed;
  }

  /// Bascule la table en statut `addition` (le client demande l'addition).
  static Future<RestaurantTable> requestBill(RestaurantTable table) async {
    final billed = table.copyWith(status: RestaurantTableStatus.addition);
    await _persist(billed);
    return billed;
  }

  /// Pose une réservation sur une table (statut `reservee`).
  static Future<RestaurantTable> reserve({
    required RestaurantTable table,
    required DateTime at,
    required String name,
    int? covers,
  }) async {
    final reserved = table.copyWith(
      status: RestaurantTableStatus.reservee,
      reservationTime: at,
      reservationName: name.trim(),
      covers: covers,
    );
    await _persist(reserved);
    return reserved;
  }

  static Future<void> deleteTable(String id, String shopId) async {
    try {
      await _raw().delete(id);
    } catch (e) {
      debugPrint('[Restaurant] deleteTable Hive err: $e');
    }
    AppDatabase.bgDelete('restaurant_tables', val: id);
    AppDatabase.notifyListeners('restaurant_tables', shopId);
  }
}
