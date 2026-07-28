import 'package:flutter/foundation.dart' show debugPrint;
import 'package:hive_flutter/hive_flutter.dart';

import '../../features/restaurant/domain/entities/ingredient.dart';
import '../database/app_database.dart';
import '../storage/hive_boxes.dart';

/// Service Hive-first du catalogue d'ingrédients (module finances — PR-A).
///
/// Même triptyque que [MenuModifierService] : écriture Hive immédiate → push
/// Supabase en arrière-plan (`bgUpsert`) → notification des listeners. Ids
/// générés côté client (`ig_` + microsecondes) → utilisable hors ligne.
class IngredientService {
  IngredientService._();

  static Box<Map> _raw() => HiveBoxes.ingredientsBox;

  static String _id() => 'ig_${DateTime.now().microsecondsSinceEpoch}';

  /// Tous les ingrédients de la boutique, triés par nom.
  static List<Ingredient> forShop(String shopId) {
    try {
      final list = <Ingredient>[];
      for (final raw in _raw().values) {
        if (raw['shop_id']?.toString() != shopId) continue;
        try {
          list.add(Ingredient.fromMap(Map<String, dynamic>.from(raw)));
        } catch (_) {/* ligne corrompue : ignorée */}
      }
      list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return list;
    } catch (e) {
      debugPrint('[Ingredient] forShop err: $e');
      return [];
    }
  }

  static Ingredient? byId(String shopId, String id) {
    try {
      final raw = _raw().get(id);
      if (raw == null) return null;
      final ing = Ingredient.fromMap(Map<String, dynamic>.from(raw));
      return ing.shopId == shopId ? ing : null;
    } catch (_) {
      return null;
    }
  }

  /// Crée un ingrédient et le retourne (pour l'attacher aussitôt à une
  /// recette). `type` par défaut 'specialized' ; il bascule en 'shared'
  /// automatiquement dès qu'un même ingrédient est lié à ≥ 2 plats
  /// (maintenu par `RecipeService`).
  ///
  /// [purchaseDate] est purement informative (hotfix_142) : elle ne crée
  /// aucune écriture de dépense — le coût matières est compté à la vente.
  static Future<Ingredient> create({
    required String shopId,
    required String name,
    String unit = 'pièce',
    int costPerUnit = 0,
    double quantity = 0,
    double alertThreshold = 0,
    DateTime? purchaseDate,
  }) async {
    final ing = Ingredient(
      id: _id(),
      shopId: shopId,
      name: name.trim(),
      unit: unit,
      costPerUnit: costPerUnit,
      quantity: quantity,
      alertThreshold: alertThreshold,
      purchaseDate: purchaseDate,
      createdAt: DateTime.now(),
    );
    await _put(ing);
    return ing;
  }

  static Future<void> update(Ingredient ing) => _put(ing);

  static Future<void> _put(Ingredient ing) async {
    final map = ing.toMap();
    try {
      await _raw().put(ing.id, map);
    } catch (e) {
      debugPrint('[Ingredient] put Hive err: $e');
    }
    AppDatabase.bgUpsert('ingredients', map);
    AppDatabase.notifyListeners('ingredients', ing.shopId);
  }

  static Future<void> delete(String id, String shopId) async {
    try {
      await _raw().delete(id);
    } catch (e) {
      debugPrint('[Ingredient] delete Hive err: $e');
    }
    AppDatabase.bgDelete('ingredients', val: id);
    AppDatabase.notifyListeners('ingredients', shopId);
  }

  /// Décrémente le stock d'un ingrédient de [amount] (jamais sous 0) — appelé
  /// par `RecipeService.consumeForOrder` à la vente.
  static Future<void> consume(
      String shopId, String ingredientId, double amount) async {
    if (amount <= 0) return;
    final ing = byId(shopId, ingredientId);
    if (ing == null) return;
    final next = ing.quantity - amount;
    await _put(ing.copyWith(quantity: next < 0 ? 0 : next));
  }
}
