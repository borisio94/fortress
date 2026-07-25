import 'package:flutter/foundation.dart' show debugPrint;
import 'package:hive_flutter/hive_flutter.dart';

import '../../features/caisse/domain/entities/sale_item.dart';
import '../../features/restaurant/domain/entities/ingredient.dart';
import '../../features/restaurant/domain/entities/recipe_ingredient.dart';
import '../database/app_database.dart';
import '../storage/hive_boxes.dart';
import 'ingredient_service.dart';
import 'notification_service.dart';

/// Service Hive-first des fiches recettes (module finances — PR-A) :
///   * CRUD des lignes (plat ↔ ingrédient, quantité) ;
///   * calcul du coût matières (prorata partagé compris) et de la marge ;
///   * décrément du stock des ingrédients à la vente.
///
/// Ids `ri_` + microsecondes. Push Supabase via `bgUpsert('recipe_ingredients')`.
class RecipeService {
  RecipeService._();

  static Box<Map> _raw() => HiveBoxes.recipeIngredientsBox;

  static String _id() => 'ri_${DateTime.now().microsecondsSinceEpoch}';

  /// Lignes de recette d'un plat.
  static List<RecipeIngredient> forProduct(String shopId, String productId) {
    try {
      final list = <RecipeIngredient>[];
      for (final raw in _raw().values) {
        if (raw['shop_id']?.toString() != shopId) continue;
        if (raw['product_id']?.toString() != productId) continue;
        try {
          list.add(RecipeIngredient.fromMap(Map<String, dynamic>.from(raw)));
        } catch (_) {/* ligne corrompue : ignorée */}
      }
      return list;
    } catch (e) {
      debugPrint('[Recipe] forProduct err: $e');
      return [];
    }
  }

  /// Nombre de plats DISTINCTS qui utilisent cet ingrédient — base du prorata
  /// de coût partagé et de la maintenance du type specialized/shared.
  static int dishCountForIngredient(String shopId, String ingredientId) {
    final products = <String>{};
    for (final raw in _raw().values) {
      if (raw['shop_id']?.toString() != shopId) continue;
      if (raw['ingredient_id']?.toString() != ingredientId) continue;
      final pid = raw['product_id']?.toString();
      if (pid != null && pid.isNotEmpty) products.add(pid);
    }
    return products.length;
  }

  /// Ajoute un ingrédient à la recette d'un plat (ou met à jour sa quantité si
  /// la ligne existe déjà — une seule ligne par couple plat/ingrédient).
  static Future<void> addLine({
    required String shopId,
    required String productId,
    required String ingredientId,
    required double quantity,
    required String unit,
  }) async {
    final existing = forProduct(shopId, productId)
        .where((l) => l.ingredientId == ingredientId)
        .toList();
    final RecipeIngredient line;
    if (existing.isNotEmpty) {
      line = existing.first.copyWith(quantity: quantity, unit: unit);
    } else {
      line = RecipeIngredient(
        id: _id(),
        shopId: shopId,
        productId: productId,
        ingredientId: ingredientId,
        quantity: quantity,
        unit: unit,
        createdAt: DateTime.now(),
      );
    }
    await _put(line);
    await _refreshIngredientType(shopId, ingredientId);
  }

  static Future<void> removeLine(RecipeIngredient line) async {
    try {
      await _raw().delete(line.id);
    } catch (e) {
      debugPrint('[Recipe] delete Hive err: $e');
    }
    AppDatabase.bgDelete('recipe_ingredients', val: line.id);
    AppDatabase.notifyListeners('recipe_ingredients', line.shopId);
    await _refreshIngredientType(line.shopId, line.ingredientId);
  }

  static Future<void> _put(RecipeIngredient line) async {
    final map = line.toMap();
    try {
      await _raw().put(line.id, map);
    } catch (e) {
      debugPrint('[Recipe] put Hive err: $e');
    }
    AppDatabase.bgUpsert('recipe_ingredients', map);
    AppDatabase.notifyListeners('recipe_ingredients', line.shopId);
  }

  /// Ajuste le `type` de l'ingrédient : 'shared' dès ≥ 2 plats l'utilisent,
  /// 'specialized' sinon. Évite une écriture inutile si le type est déjà bon.
  static Future<void> _refreshIngredientType(
      String shopId, String ingredientId) async {
    final ing = IngredientService.byId(shopId, ingredientId);
    if (ing == null) return;
    final wanted =
        dishCountForIngredient(shopId, ingredientId) >= 2 ? 'shared' : 'specialized';
    if (ing.type != wanted) {
      await IngredientService.update(ing.copyWith(type: wanted));
    }
  }

  // ── Calculs coût / marge ────────────────────────────────────────────────

  /// Coût d'une ligne POUR CE PLAT, prorata partagé compris :
  ///   (quantité_recette × coût_unitaire) ÷ nb_plats_utilisant.
  static double lineCost(String shopId, RecipeIngredient line) {
    final ing = IngredientService.byId(shopId, line.ingredientId);
    if (ing == null) return 0;
    final raw = line.quantity * ing.costPerUnit;
    if (!ing.isShared) return raw;
    final n = dishCountForIngredient(shopId, line.ingredientId);
    return n <= 1 ? raw : raw / n;
  }

  /// Coût matières total d'un plat (Σ des coûts de ligne).
  static double recipeCost(String shopId, String productId) {
    double total = 0;
    for (final l in forProduct(shopId, productId)) {
      total += lineCost(shopId, l);
    }
    return total;
  }

  /// Marge brute d'un plat en FCFA : prix de vente − coût matières.
  static double margin(String shopId, String productId, double sellPrice) =>
      sellPrice - recipeCost(shopId, productId);

  /// Marge en % du prix de vente (0 si prix nul).
  static double marginPct(String shopId, String productId, double sellPrice) =>
      sellPrice <= 0 ? 0 : (margin(shopId, productId, sellPrice) / sellPrice) * 100;

  // ── Décrément à la vente ────────────────────────────────────────────────

  /// Retire du stock les ingrédients consommés par les plats vendus, et émet
  /// une alerte in-app « ingrédient bas » pour ceux passés sous leur seuil.
  ///
  /// Le décrément PHYSIQUE retire la quantité réelle utilisée
  /// (`quantité_recette × quantité_vendue`) — le prorata partagé ne concerne
  /// QUE le coût, jamais le stock. Retourne la liste (dédupliquée) des
  /// ingrédients désormais sous leur seuil (utile aux tests / appelants).
  static Future<List<Ingredient>> consumeForOrder(
      String shopId, List<SaleItem> items) async {
    final low = <String, Ingredient>{};
    for (final item in items) {
      final pid = item.productId;
      if (pid.isEmpty) continue;
      for (final line in forProduct(shopId, pid)) {
        await IngredientService.consume(
            shopId, line.ingredientId, line.quantity * item.quantity);
        final ing = IngredientService.byId(shopId, line.ingredientId);
        if (ing != null && ing.isLowStock) low[ing.id] = ing;
      }
    }
    // Alertes stock bas ingrédient (dédup 60s côté NotificationService).
    if (low.isNotEmpty && NotificationService.enabledForCurrentUser.value) {
      for (final ing in low.values) {
        final q = ing.quantity == ing.quantity.truncateToDouble()
            ? ing.quantity.toInt().toString()
            : ing.quantity.toStringAsFixed(1);
        NotificationService.notify(
          kind: NotifKind.stockLow,
          title: '⚠ Ingrédient bas',
          message: '${ing.name} · Stock : $q ${ing.unit}',
          shopId: shopId,
          targetId: ing.id,
        );
      }
    }
    return low.values.toList();
  }
}
