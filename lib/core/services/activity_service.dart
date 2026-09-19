import 'package:flutter/foundation.dart' show debugPrint;
import 'package:hive_flutter/hive_flutter.dart';

import '../../features/restaurant/domain/entities/restaurant_activity.dart';
import '../database/app_database.dart';
import '../storage/hive_boxes.dart';

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

  static Future<void> delete(String id, String shopId) async {
    try {
      await _raw().delete(id);
    } catch (e) {
      debugPrint('[Activity] delete Hive err: $e');
    }
    AppDatabase.bgDelete('restaurant_activities', val: id);
    AppDatabase.notifyListeners('restaurant_activities', shopId);
  }
}
