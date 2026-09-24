import 'package:flutter/foundation.dart' show debugPrint;
import 'package:hive_flutter/hive_flutter.dart';

import '../../features/restaurant/domain/entities/restaurant_activity.dart';
import '../database/app_database.dart';
import '../storage/hive_boxes.dart';
import '../storage/local_storage_service.dart';
import 'stock_item_service.dart';

/// Service Hive-first des activités connexes (module finances — PR-B).
/// Ids `ra_` + microsecondes. Push Supabase via `bgUpsert('restaurant_activities')`.
class ActivityService {
  ActivityService._();

  static Box<Map> _raw() => HiveBoxes.restaurantActivitiesBox;

  static String _id() => 'ra_${DateTime.now().microsecondsSinceEpoch}';

  static List<RestaurantActivity> forShop(String shopId) {
    try {
      final list = <RestaurantActivity>[];
      for (final raw in _raw().values) {
        if (raw['shop_id']?.toString() != shopId) continue;
        try {
          list.add(RestaurantActivity.fromMap(Map<String, dynamic>.from(raw)));
        } catch (_) {/* ligne corrompue : ignorée */}
      }
      list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return list;
    } catch (e) {
      debugPrint('[Activity] forShop err: $e');
      return [];
    }
  }

  static RestaurantActivity? byId(String shopId, String id) {
    try {
      final raw = _raw().get(id);
      if (raw == null) return null;
      final a = RestaurantActivity.fromMap(Map<String, dynamic>.from(raw));
      return a.shopId == shopId ? a : null;
    } catch (_) {
      return null;
    }
  }

  static Future<RestaurantActivity> create({
    required String shopId,
    required String name,
    String mode = 'stock',
    int stockThreshold = 0,
    String? station,
  }) async {
    final a = RestaurantActivity(
      id: _id(),
      shopId: shopId,
      name: name.trim(),
      mode: mode,
      stockThreshold: stockThreshold,
      station: station,
      createdAt: DateTime.now(),
    );
    await _put(a);
    return a;
  }

  static Future<void> update(RestaurantActivity a) => _put(a);

  static Future<void> _put(RestaurantActivity a) async {
    final map = a.toMap();
    try {
      await _raw().put(a.id, map);
    } catch (e) {
      debugPrint('[Activity] put Hive err: $e');
    }
    AppDatabase.bgUpsert('restaurant_activities', map);
    AppDatabase.notifyListeners('restaurant_activities', a.shopId);
  }

  /// Ce qu'une suppression détacherait : plats et articles de stock rattachés.
  ///
  /// Compté sur CET appareil. Un plat créé ailleurs et pas encore synchronisé
  /// n'y figure pas — mais le détachement, lui, l'atteindra (voir [delete]).
  static ({int dishes, int stockItems}) attachedTo(String shopId, String id) {
    var dishes = 0;
    var items = 0;
    try {
      for (final p in LocalStorageService.getProductsForShop(shopId)) {
        if (p.activityId == id) dishes++;
      }
      for (final s in StockItemService.forShop(shopId)) {
        if (s.activityId == id) items++;
      }
    } catch (e) {
      debugPrint('[Activity] attachedTo err: $e');
    }
    return (dishes: dishes, stockItems: items);
  }

  /// « 4 plats et 2 articles de stock » — `null` si rien n'est rattaché.
  static String? attachedLabel(int dishes, int stockItems) {
    String n(int v, String one, String many) => '$v ${v > 1 ? many : one}';
    final parts = [
      if (dishes > 0) n(dishes, 'plat', 'plats'),
      if (stockItems > 0) n(stockItems, 'article de stock', 'articles de stock'),
    ];
    return parts.isEmpty ? null : parts.join(' et ');
  }

  /// Supprime l'activité ET DÉTACHE ce qui s'y rattachait.
  ///
  /// Sans détachement, plats et articles gardaient un identifiant mort : pas
  /// de clé étrangère pour l'empêcher (offline-first, hotfix_141). Le rapport
  /// les rangeait alors sur une SECONDE ligne « Sans secteur », qui comptait en
  /// outre comme une activité réelle et pouvait faire réapparaître la carte
  /// « Par secteur » alors qu'il n'en restait aucune.
  ///
  /// Le détachement passe par UN `UPDATE … WHERE activity_id = <id>` en file :
  /// il atteint aussi les lignes que cet appareil ne connaît pas encore.
  /// Localement, seul le champ `activity_id` est remis à null — pas de
  /// `saveProduct`, qui revaliderait le plat, journaliserait son stock et
  /// repousserait la ligne entière pour un seul champ.
  ///
  /// Détacher AVANT de supprimer : interrompu entre les deux, on garde une
  /// activité sans plat, jamais des plats sans activité.
  static Future<void> delete(String id, String shopId) async {
    await _detach(
      box: HiveBoxes.productsBox,
      table: 'products',
      shopColumn: 'store_id',
      shopId: shopId,
      id: id,
    );
    LocalStorageService.invalidateProductsCache();
    await _detach(
      box: HiveBoxes.stockItemsBox,
      table: 'stock_items',
      shopColumn: 'shop_id',
      shopId: shopId,
      id: id,
    );
    AppDatabase.notifyListeners('products', shopId);
    AppDatabase.notifyListeners('stock_items', shopId);
    try {
      await _raw().delete(id);
    } catch (e) {
      debugPrint('[Activity] delete Hive err: $e');
    }
    AppDatabase.bgDelete('restaurant_activities', val: id);
    AppDatabase.notifyListeners('restaurant_activities', shopId);
  }

  /// Remet `activity_id` à null sur les lignes de [shopId] rattachées à [id],
  /// dans Hive puis en base.
  ///
  /// L'ordre serveur part MÊME si Hive n'avait rien : c'est lui qui rattrape
  /// les lignes créées sur un autre appareil.
  static Future<void> _detach({
    required Box<Map> box,
    required String table,
    required String shopColumn,
    required String shopId,
    required String id,
  }) async {
    try {
      for (final key in box.keys.toList()) {
        final raw = box.get(key);
        if (raw == null) continue;
        if (raw[shopColumn]?.toString() != shopId) continue;
        if (raw['activity_id']?.toString() != id) continue;
        await box.put(key, Map<String, dynamic>.from(raw)..['activity_id'] = null);
      }
    } catch (e) {
      debugPrint('[Activity] détachement $table Hive err: $e');
    }
    AppDatabase.bgUpdateWhere(table,
        match: {shopColumn: shopId, 'activity_id': id},
        data: {'activity_id': null});
  }
}
