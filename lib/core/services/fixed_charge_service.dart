import 'package:flutter/foundation.dart' show debugPrint;
import 'package:hive_flutter/hive_flutter.dart';

import '../../features/restaurant/domain/entities/fixed_charge.dart';
import '../database/app_database.dart';
import '../storage/hive_boxes.dart';

/// Service Hive-first des charges fixes / échéances récurrentes (module
/// finances — PR-C). Ids `fc_` + microsecondes. Push Supabase via
/// `bgUpsert('fixed_charges')`.
class FixedChargeService {
  FixedChargeService._();

  static Box<Map> _raw() => HiveBoxes.fixedChargesBox;

  static String _id() => 'fc_${DateTime.now().microsecondsSinceEpoch}';

  static List<FixedCharge> forShop(String shopId) {
    try {
      final list = <FixedCharge>[];
      for (final raw in _raw().values) {
        if (raw['shop_id']?.toString() != shopId) continue;
        try {
          list.add(FixedCharge.fromMap(Map<String, dynamic>.from(raw)));
        } catch (_) {/* ligne corrompue : ignorée */}
      }
      // Les plus urgentes d'abord (échéance la plus proche en tête).
      list.sort((a, b) => a.nextDueDate.compareTo(b.nextDueDate));
      return list;
    } catch (e) {
      debugPrint('[FixedCharge] forShop err: $e');
      return [];
    }
  }

  static FixedCharge? byId(String shopId, String id) {
    try {
      final raw = _raw().get(id);
      if (raw == null) return null;
      final c = FixedCharge.fromMap(Map<String, dynamic>.from(raw));
      return c.shopId == shopId ? c : null;
    } catch (_) {
      return null;
    }
  }

  static Future<FixedCharge> create({
    required String shopId,
    required String name,
    required DateTime nextDueDate,
    int amount = 0,
    String frequency = 'monthly',
    int alertDaysBefore = 7,
    String category = 'autre',
  }) async {
    final c = FixedCharge(
      id: _id(),
      shopId: shopId,
      name: name.trim(),
      nextDueDate: nextDueDate,
      amount: amount,
      frequency: frequency,
      alertDaysBefore: alertDaysBefore,
      category: category,
      createdAt: DateTime.now(),
    );
    await _put(c);
    return c;
  }

  static Future<void> update(FixedCharge c) => _put(c);

  static Future<void> _put(FixedCharge c) async {
    final map = c.toMap();
    try {
      await _raw().put(c.id, map);
    } catch (e) {
      debugPrint('[FixedCharge] put Hive err: $e');
    }
    AppDatabase.bgUpsert('fixed_charges', map);
    AppDatabase.notifyListeners('fixed_charges', c.shopId);
  }

  static Future<void> delete(String id, String shopId) async {
    try {
      await _raw().delete(id);
    } catch (e) {
      debugPrint('[FixedCharge] delete Hive err: $e');
    }
    AppDatabase.bgDelete('fixed_charges', val: id);
    AppDatabase.notifyListeners('fixed_charges', shopId);
  }

  /// Marque l'échéance courante comme réglée et avance [nextDueDate] à la
  /// période suivante selon la fréquence. Idempotent sur une même échéance.
  static Future<void> markPaid(String shopId, String id) async {
    final c = byId(shopId, id);
    if (c == null) return;
    final key = FixedCharge.dayKey(c.nextDueDate);
    final paid = List<String>.from(c.paidDates);
    if (!paid.contains(key)) paid.add(key);
    await _put(c.copyWith(
      paidDates: paid,
      nextDueDate: _advance(c.nextDueDate, c.frequency),
    ));
  }

  /// Prochaine échéance selon la fréquence (borne « once » = inchangée).
  static DateTime _advance(DateTime from, String frequency) {
    switch (frequency) {
      case 'monthly':
        return DateTime(from.year, from.month + 1, from.day);
      case 'quarterly':
        return DateTime(from.year, from.month + 3, from.day);
      case 'yearly':
        return DateTime(from.year + 1, from.month, from.day);
      default: // 'once'
        return from;
    }
  }

  /// Charges à régler bientôt (fenêtre d'alerte) ou en retard — pour le badge.
  static List<FixedCharge> dueSoon(String shopId) =>
      forShop(shopId).where((c) => c.isDueSoon).toList();
}
