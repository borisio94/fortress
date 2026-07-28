import 'package:flutter/foundation.dart' show debugPrint;
import 'package:hive_flutter/hive_flutter.dart';

import '../../features/restaurant/domain/entities/daily_expense.dart';
import '../database/app_database.dart';
import '../storage/hive_boxes.dart';

/// Service Hive-first des dépenses quotidiennes (Lot E — hotfix_149).
/// Ids `de_` + microsecondes. Push Supabase via `bgUpsert('daily_expenses')`.
///
/// Deux lectures en dépendent, et elles ne parlent pas de la même chose :
///   * [foodCost] — les achats de matières d'une période : le « food cost
///     réel », à comparer au coût théorique des fiches recettes ;
///   * [cashOut] — ce qui est sorti du TIROIR : déduit du total attendu à la
///     clôture de caisse, sinon chaque achat au marché passe pour un manquant.
class DailyExpenseService {
  DailyExpenseService._();

  static Box<Map> _raw() => HiveBoxes.dailyExpensesBox;

  static String _id() => 'de_${DateTime.now().microsecondsSinceEpoch}';

  /// Dépenses de la boutique, les plus récentes en tête.
  static List<DailyExpense> forShop(
    String shopId, {
    DateTime? from,
    DateTime? to,
    ExpenseKind? kind,
  }) {
    try {
      final list = <DailyExpense>[];
      for (final raw in _raw().values) {
        if (raw['shop_id']?.toString() != shopId) continue;
        try {
          final e = DailyExpense.fromMap(Map<String, dynamic>.from(raw));
          if (kind != null && e.kind != kind) continue;
          if (from != null && e.expenseDate.isBefore(_dayStart(from))) continue;
          if (to != null && e.expenseDate.isAfter(_dayEnd(to))) continue;
          list.add(e);
        } catch (_) {/* ligne corrompue : ignorée */}
      }
      list.sort((a, b) => b.expenseDate.compareTo(a.expenseDate));
      return list;
    } catch (e) {
      debugPrint('[DailyExpense] forShop err: $e');
      return [];
    }
  }

  /// Total des dépenses d'une période, toutes catégories.
  static int total(String shopId, {DateTime? from, DateTime? to}) =>
      forShop(shopId, from: from, to: to).fold(0, (s, e) => s + e.amount);

  /// FOOD COST RÉEL : les achats de matières premières de la période.
  static int foodCost(String shopId, {DateTime? from, DateTime? to}) =>
      forShop(shopId, from: from, to: to, kind: ExpenseKind.achatMarche)
          .fold(0, (s, e) => s + e.amount);

  /// Tout ce qui n'est PAS de la matière première — l'exploitation courante
  /// (électricité, gaz, transport…).
  static int operatingCost(String shopId, {DateTime? from, DateTime? to}) =>
      forShop(shopId, from: from, to: to)
          .where((e) => !e.isFoodCost)
          .fold(0, (s, e) => s + e.amount);

  /// Espèces sorties du tiroir sur la période.
  ///
  /// Utilisé par la clôture de caisse : sans cette déduction, un achat de
  /// 30 000 F payé du tiroir apparaît le soir comme un manquant de 30 000 F, et
  /// le caissier est suspecté d'un vol qu'il n'a pas commis.
  static int cashOut(String shopId, {DateTime? from, DateTime? to}) =>
      forShop(shopId, from: from, to: to)
          .where((e) => e.isCash)
          .fold(0, (s, e) => s + e.amount);

  /// Répartition par catégorie, du plus gros au plus petit.
  static List<({ExpenseKind kind, int amount})> byCategory(
    String shopId, {
    DateTime? from,
    DateTime? to,
  }) {
    final totals = <ExpenseKind, int>{};
    for (final e in forShop(shopId, from: from, to: to)) {
      totals[e.kind] = (totals[e.kind] ?? 0) + e.amount;
    }
    final out = [
      for (final entry in totals.entries)
        (kind: entry.key, amount: entry.value),
    ]..sort((a, b) => b.amount.compareTo(a.amount));
    return out;
  }

  static Future<DailyExpense> record({
    required String shopId,
    required String description,
    required int amount,
    ExpenseKind kind = ExpenseKind.achatMarche,
    String? paidBy,
    bool isCash = true,
    DateTime? date,
  }) async {
    final e = DailyExpense(
      id: _id(),
      shopId: shopId,
      description: description.trim(),
      amount: amount,
      category: kind.key,
      paidBy: paidBy,
      isCash: isCash,
      expenseDate: date ?? DateTime.now(),
      createdAt: DateTime.now(),
    );
    await _put(e);
    return e;
  }

  static Future<void> update(DailyExpense e) => _put(e);

  static Future<void> _put(DailyExpense e) async {
    final map = e.toMap();
    try {
      await _raw().put(e.id, map);
    } catch (err) {
      debugPrint('[DailyExpense] put Hive err: $err');
    }
    AppDatabase.bgUpsert('daily_expenses', map);
    AppDatabase.notifyListeners('daily_expenses', e.shopId);
  }

  static Future<void> delete(String id, String shopId) async {
    try {
      await _raw().delete(id);
    } catch (e) {
      debugPrint('[DailyExpense] delete Hive err: $e');
    }
    AppDatabase.bgDelete('daily_expenses', val: id);
    AppDatabase.notifyListeners('daily_expenses', shopId);
  }

  /// Les dépenses sont datées au JOUR : comparer à une heure précise
  /// exclurait celles du jour même de la borne.
  static DateTime _dayStart(DateTime d) => DateTime(d.year, d.month, d.day);

  static DateTime _dayEnd(DateTime d) =>
      DateTime(d.year, d.month, d.day, 23, 59, 59);
}
