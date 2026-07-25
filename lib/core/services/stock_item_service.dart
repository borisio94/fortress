import 'package:flutter/foundation.dart' show debugPrint;
import 'package:hive_flutter/hive_flutter.dart';

import '../../features/restaurant/domain/entities/stock_item.dart';
import '../database/app_database.dart';
import '../storage/hive_boxes.dart';

/// Service Hive-first des articles sans transformation (module finances — PR-B).
/// Ids `si_` + microsecondes. Push Supabase via `bgUpsert('stock_items')`.
class StockItemService {
  StockItemService._();

  static Box<Map> _raw() => HiveBoxes.stockItemsBox;

  static String _id() => 'si_${DateTime.now().microsecondsSinceEpoch}';

  static List<StockItem> forShop(String shopId) {
    try {
      final list = <StockItem>[];
      for (final raw in _raw().values) {
        if (raw['shop_id']?.toString() != shopId) continue;
        try {
          list.add(StockItem.fromMap(Map<String, dynamic>.from(raw)));
        } catch (_) {/* ligne corrompue : ignorée */}
      }
      list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return list;
    } catch (e) {
      debugPrint('[StockItem] forShop err: $e');
      return [];
    }
  }

  static StockItem? byId(String shopId, String id) {
    try {
      final raw = _raw().get(id);
      if (raw == null) return null;
      final s = StockItem.fromMap(Map<String, dynamic>.from(raw));
      return s.shopId == shopId ? s : null;
    } catch (_) {
      return null;
    }
  }

  static Future<StockItem> create({
    required String shopId,
    required String name,
    required String unit,
    double quantity = 0,
    double minQuantity = 0,
    int costPerUnit = 0,
    int sellingPrice = 0,
    String? activityId,
  }) async {
    final s = StockItem(
      id: _id(),
      shopId: shopId,
      name: name.trim(),
      unit: unit,
      quantity: quantity,
      minQuantity: minQuantity,
      costPerUnit: costPerUnit,
      sellingPrice: sellingPrice,
      activityId: activityId,
      createdAt: DateTime.now(),
    );
    await _put(s);
    return s;
  }

  static Future<void> update(StockItem s) => _put(s);

  static Future<void> _put(StockItem s) async {
    final map = s.toMap();
    try {
      await _raw().put(s.id, map);
    } catch (e) {
      debugPrint('[StockItem] put Hive err: $e');
    }
    AppDatabase.bgUpsert('stock_items', map);
    AppDatabase.notifyListeners('stock_items', s.shopId);
  }

  static Future<void> delete(String id, String shopId) async {
    try {
      await _raw().delete(id);
    } catch (e) {
      debugPrint('[StockItem] delete Hive err: $e');
    }
    AppDatabase.bgDelete('stock_items', val: id);
    AppDatabase.notifyListeners('stock_items', shopId);
  }

  /// Réception : ajoute [amount] au stock (entrée de marchandise).
  static Future<void> receive(String shopId, String id, double amount) async {
    if (amount <= 0) return;
    final s = byId(shopId, id);
    if (s == null) return;
    await _put(s.copyWith(quantity: s.quantity + amount));
  }

  /// Articles au niveau ou sous leur seuil minimal (badge / alertes).
  static List<StockItem> lowStock(String shopId) =>
      forShop(shopId).where((s) => s.isLowStock).toList();
}
