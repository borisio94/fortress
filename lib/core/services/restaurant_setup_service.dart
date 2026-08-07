import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import '../../features/restaurant/domain/entities/ingredient.dart';
import '../storage/local_storage_service.dart';
import 'daily_expense_service.dart';
import 'ingredient_service.dart';
import 'recipe_service.dart';
import 'restaurant_table_service.dart';

/// Où en est la mise en route d'un restaurant.
///
/// L'ordre n'est pas décoratif, chaque étape conditionne la suivante :
///   * sans table, aucun service ne peut s'ouvrir ;
///   * sans plat composé, la caisse vend des articles dont on ignore la
///     composition ;
///   * sans achat rattaché aux ingrédients, ces plats coûtent 0 F — la marge
///     affichée est flatteuse et fausse, et tout le module finances rend zéro.
///
/// Ouvrir l'application entière à quelqu'un qui n'a rien saisi, c'est lui
/// montrer huit écrans vides et le laisser deviner par où commencer.
enum RestaurantSetupStep {
  /// Aucune table : rien ne peut être ouvert au service.
  needsTable,

  /// Des tables existent, mais aucun plat ne porte d'ingrédient.
  needsMenuItem,

  /// Des plats composés existent, mais leurs ingrédients n'ont coûté
  /// « officiellement » rien : aucune dépense ne leur est rattachée.
  needsIngredientCost,

  /// Le restaurant peut fonctionner, et ses chiffres veulent dire quelque
  /// chose.
  complete;

  bool get isComplete => this == RestaurantSetupStep.complete;

  /// Rang de l'étape (1 à 3), pour le stepper.
  int get index1 => switch (this) {
        RestaurantSetupStep.needsTable => 1,
        RestaurantSetupStep.needsMenuItem => 2,
        _ => 3,
      };

  /// Nombre total d'étapes du parcours.
  static const int totalSteps = 3;
}

/// Calcul de l'étape de mise en route.
///
/// TOUT est déduit de Hive, à la demande — aucun drapeau séparé n'est stocké.
/// Un drapeau aurait dû être maintenu à chaque création et à chaque
/// suppression, et se serait désynchronisé au premier chemin oublié : un
/// restaurant qui supprime sa dernière table serait resté « configuré » avec
/// une salle vide. Ici, la réponse ne peut pas mentir — elle EST l'état des
/// données. Corollaire : aucune requête réseau, donc fonctionne hors ligne.
class RestaurantSetupService {
  RestaurantSetupService._();

  static RestaurantSetupStep stepFor(String shopId) {
    if (shopId.isEmpty) return RestaurantSetupStep.complete;
    try {
      return decide(
        hasTable: RestaurantTableService.tablesForShop(shopId).isNotEmpty,
        hasComposedDish: _hasComposedDish(shopId),
        hasIngredientCost: ingredientsWithoutCost(shopId).isEmpty,
      );
    } catch (e) {
      // En cas de doute on ne BLOQUE PAS : une boîte Hive indisponible ne doit
      // pas enfermer un restaurant déjà en service dans un écran de
      // configuration dont il ne pourrait pas sortir.
      debugPrint('[RestoSetup] err: $e');
      return RestaurantSetupStep.complete;
    }
  }

  /// La règle, isolée de Hive pour être vérifiable directement.
  @visibleForTesting
  static RestaurantSetupStep decide({
    required bool hasTable,
    required bool hasComposedDish,
    required bool hasIngredientCost,
  }) {
    if (!hasTable) return RestaurantSetupStep.needsTable;
    if (!hasComposedDish) return RestaurantSetupStep.needsMenuItem;
    if (!hasIngredientCost) return RestaurantSetupStep.needsIngredientCost;
    return RestaurantSetupStep.complete;
  }

  /// INGRÉDIENTS QUI COMPOSENT UN PLAT MAIS N'ONT JAMAIS RIEN COÛTÉ.
  ///
  /// Le filtre porte sur les ingrédients RÉELLEMENT UTILISÉS : un ingrédient
  /// créé puis oublié dans un coin du catalogue ne doit pas bloquer la mise en
  /// route, il ne fausse le coût d'aucun plat.
  ///
  /// « Rien coûté » veut dire : aucune dépense ne porte son identifiant. C'est
  /// exactement ce qui fait qu'un plat s'affiche à 0 F — la répartition n'a
  /// rien à répartir.
  static List<Ingredient> ingredientsWithoutCost(String shopId) {
    try {
      final used = <String>{};
      for (final l in RecipeService.forShop(shopId)) {
        used.add(l.ingredientId);
      }
      if (used.isEmpty) return const [];

      final paid = <String>{};
      for (final e in DailyExpenseService.forShop(shopId)) {
        final id = e.ingredientId;
        if (id != null && id.isNotEmpty) paid.add(id);
      }

      return IngredientService.forShop(shopId)
          .where((i) => used.contains(i.id) && !paid.contains(i.id))
          .toList();
    } catch (e) {
      // Même parti pris que `stepFor` : en cas de doute, on ne bloque pas.
      debugPrint('[RestoSetup] coûts err: $e');
      return const [];
    }
  }

  /// Existe-t-il au moins un plat VIVANT portant un ingrédient ?
  ///
  /// Le croisement avec le catalogue est indispensable : les liens de recette
  /// survivent au soft-delete d'un plat (restaurer le plat doit restaurer sa
  /// composition). Sans ce filtre, un restaurant ayant supprimé son unique
  /// plat resterait considéré comme configuré.
  static bool _hasComposedDish(String shopId) {
    final links = RecipeService.forShop(shopId);
    if (links.isEmpty) return false;
    final linked = {for (final l in links) l.productId};
    for (final p in LocalStorageService.getProductsForShop(shopId)) {
      final id = p.id;
      if (id != null && linked.contains(id)) return true;
    }
    return false;
  }
}
