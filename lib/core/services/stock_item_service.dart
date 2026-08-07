import 'package:flutter/foundation.dart' show debugPrint;
import 'package:hive_flutter/hive_flutter.dart';

import '../../features/restaurant/domain/entities/daily_expense.dart';
import '../../features/restaurant/domain/entities/stock_item.dart';
import '../database/app_database.dart';
import '../storage/hive_boxes.dart';
import 'daily_expense_service.dart';
import 'notification_service.dart';

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

  /// Retire [amount] du stock (jamais sous 0) et alerte si le seuil minimal
  /// est atteint.
  ///
  /// Appelé quand un emballage est réellement UTILISÉ : barquettes d'une
  /// commande à emporter, sachets pour des restes. C'est le pendant du
  /// décrément des boissons — aujourd'hui, boissons et emballages sont les
  /// deux seules choses dont le stock bouge à la vente. Les plats n'en ont
  /// pas, et les ingrédients ne se décrémentent plus depuis le passage à la
  /// répartition au prorata.
  ///
  /// Retourne l'article mis à jour, `null` s'il a disparu entre-temps.
  static Future<StockItem?> consume(
      String shopId, String id, double amount) async {
    if (amount <= 0) return byId(shopId, id);
    // Relecture juste avant écriture : entre l'ouverture de la feuille et sa
    // validation, un autre poste a pu recevoir de la marchandise, et un
    // copyWith sur un objet périmé écraserait cette réception.
    final fresh = byId(shopId, id);
    if (fresh == null) return null;
    final next = fresh.quantity - amount;
    final updated = fresh.copyWith(quantity: next < 0 ? 0 : next);
    await _put(updated);

    if (updated.isLowStock && NotificationService.enabledForCurrentUser.value) {
      final q = updated.quantity == updated.quantity.truncateToDouble()
          ? updated.quantity.toInt().toString()
          : updated.quantity.toStringAsFixed(1);
      NotificationService.notify(
        kind: NotifKind.stockLow,
        title: '⚠ Fourniture basse',
        message: '${updated.name} · Stock : $q ${updated.unit}',
        shopId: shopId,
        targetId: updated.id,
      );
    }
    return updated;
  }

  /// Articles au niveau ou sous leur seuil minimal (badge / alertes).
  static List<StockItem> lowStock(String shopId) =>
      forShop(shopId).where((s) => s.isLowStock).toList();

  // ── Régularisation des achats non enregistrés ───────────────────────────
  //
  // Les fournitures créées avant que le formulaire n'écrive une dépense
  // portent un stock et un coût, mais aucun franc ne leur est rattaché : le
  // gaz, les barquettes et le charbon sont sortis de la caisse sans laisser de
  // trace dans les comptes. Ces trois fonctions rattrapent ce passé, sur le
  // modèle éprouvé des ingrédients.

  /// Fournitures ayant un coût unitaire mais dont aucun achat n'a jamais été
  /// enregistré en dépense.
  ///
  /// Le filtre sur la dépense EXISTANTE est ce qui rend la régularisation
  /// rejouable sans risque : la relancer deux fois ne double aucun montant.
  /// Le lien passe par `daily_expenses.ingredient_id`, qui porte ici un id
  /// `si_…` — cf. [DailyExpenseService.spendByIngredient] pour la garde qui
  /// empêche ces achats d'entrer dans le coût matières.
  static List<StockItem> withoutRecordedPurchase(String shopId) {
    final linked = <String>{};
    try {
      for (final e in DailyExpenseService.forShop(shopId)) {
        final id = e.ingredientId;
        if (id != null && id.isNotEmpty) linked.add(id);
      }
    } catch (e) {
      // En cas de doute on ne propose RIEN : mieux vaut ne pas régulariser que
      // créer des doublons de dépenses.
      debugPrint('[StockItem] lecture dépenses err: $e');
      return const [];
    }
    return forShop(shopId)
        .where((s) => s.costPerUnit > 0 && !linked.contains(s.id))
        .toList();
  }

  /// Montant qu'une régularisation écrirait : la valeur du stock déclaré.
  ///
  /// Stock à zéro → on retient UNE unité. Une fourniture saisie sans quantité
  /// a bien été achetée ; l'ignorer laisserait son coût invisible, ce que la
  /// régularisation cherche précisément à corriger.
  static int backfillAmountFor(StockItem s) =>
      (s.costPerUnit * (s.quantity <= 0 ? 1 : s.quantity)).round();

  /// Écrit une dépense par fourniture de [withoutRecordedPurchase].
  ///
  /// Datée du jour de CRÉATION de la fourniture, pas d'aujourd'hui : l'argent
  /// est sorti à ce moment-là, et l'imputer au mois courant fausserait deux
  /// bilans d'un coup. Marquée HORS ESPÈCES — ces achats sont anciens, les
  /// compter comme sorties du tiroir ferait apparaître un manquant massif à la
  /// prochaine clôture de caisse.
  ///
  /// Catégorie « Autre » : une fourniture n'est pas de la matière première, la
  /// verser dans le food cost fausserait le ratio qui juge la carte.
  static Future<({int count, int total})> recordMissingPurchases(
      String shopId) async {
    var count = 0;
    var total = 0;
    for (final s in withoutRecordedPurchase(shopId)) {
      final amount = backfillAmountFor(s);
      if (amount <= 0) continue;
      try {
        await DailyExpenseService.record(
          shopId: shopId,
          description: s.quantity > 0
              ? '${s.name} — ${_fmtQty(s.quantity)} ${s.unit}'.trim()
              : s.name,
          amount: amount,
          kind: ExpenseKind.autre,
          date: s.createdAt,
          ingredientId: s.id,
          isCash: false,
        );
        count++;
        total += amount;
      } catch (e) {
        debugPrint('[StockItem] régularisation ${s.name} err: $e');
      }
    }
    if (count > 0) AppDatabase.notifyListeners('daily_expenses', shopId);
    return (count: count, total: total);
  }

  /// Quantité lisible, sans « .0 » superflu.
  static String _fmtQty(double v) =>
      v == v.truncateToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

  /// Fournitures VENDABLES — celles qui portent un prix de vente.
  ///
  /// Ce sont les emballages qu'on facture : barquettes, sachets, boîtes. Le
  /// gaz et les produits d'entretien n'en ont pas et n'ont rien à faire dans
  /// une feuille d'emballage.
  static List<StockItem> sellable(String shopId) =>
      forShop(shopId).where((s) => s.sellingPrice > 0).toList();
}
