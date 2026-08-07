import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import '../storage/hive_boxes.dart';
import 'daily_expense_service.dart';
import 'ingredient_allocation_service.dart';
import 'ingredient_service.dart';
import 'recipe_service.dart';

/// Les deux façons de chiffrer le coût matières d'un plat.
///
/// Elles sont SÉPARÉES et exclusives : une boutique en active une, jamais les
/// deux à la fois. Elles ne mesurent pas la même chose, et les additionner ou
/// les mélanger plat par plat donnerait un chiffre qui n'aurait de sens dans
/// aucune des deux logiques.
enum DishCostMethod {
  /// RÉPARTITION AU PRORATA (défaut, méthode historique).
  ///
  /// Les achats de la période se répartissent entre les plats vendus qui
  /// portent l'ingrédient. Aucune quantité n'est demandée. Fidèle à la
  /// TRÉSORERIE : le coût d'un plat bouge d'un mois à l'autre au gré des
  /// achats, et rien ne détecte un sur-dosage.
  repartition,

  /// FICHE TECHNIQUE.
  ///
  /// Coût d'un plat = somme des (quantité par portion × coût unitaire moyen
  /// pondéré de l'ingrédient). Fidèle à la RECETTE : stable d'une période à
  /// l'autre, indépendante du rythme des achats. Exige que chaque ligne de la
  /// fiche porte une quantité confirmée.
  technicalSheet;

  String get key => switch (this) {
        DishCostMethod.repartition => 'repartition',
        DishCostMethod.technicalSheet => 'technical_sheet',
      };

  String get label => switch (this) {
        DishCostMethod.repartition => 'Répartition des achats',
        DishCostMethod.technicalSheet => 'Fiche technique',
      };

  String get description => switch (this) {
        DishCostMethod.repartition =>
          'Les achats du mois se répartissent entre les plats vendus qui '
              'contiennent l\'ingrédient. Aucune quantité à peser. Le coût '
              'suit la trésorerie et varie d\'un mois à l\'autre.',
        DishCostMethod.technicalSheet =>
          'Chaque plat est chiffré sur les quantités de sa fiche. Le coût est '
              'stable et indépendant du rythme des achats, mais chaque ligne '
              'de recette doit porter une quantité.',
      };

  static DishCostMethod fromKey(String? s) => switch (s) {
        'technical_sheet' => DishCostMethod.technicalSheet,
        _ => DishCostMethod.repartition,
      };
}

/// Méthode retenue par boutique.
///
/// Rangée dans la box `settings` sous `dish_cost_method_<shopId>`, comme les
/// catégories et les unités — c'est la convention du projet pour un réglage
/// attaché à une boutique. Conséquence à connaître : le réglage est LOCAL À
/// L'APPAREIL. Deux tablettes de la même boutique peuvent afficher des coûts
/// différents tant que la méthode n'y est pas réglée pareil.
class DishCostSettings {
  DishCostSettings._();

  static String _key(String shopId) => 'dish_cost_method_$shopId';

  static DishCostMethod forShop(String shopId) {
    if (shopId.isEmpty) return DishCostMethod.repartition;
    try {
      return DishCostMethod.fromKey(
          HiveBoxes.settingsBox.get(_key(shopId))?.toString());
    } catch (e) {
      debugPrint('[DishCost] lecture méthode err: $e');
      return DishCostMethod.repartition;
    }
  }

  static Future<void> setForShop(String shopId, DishCostMethod m) async {
    if (shopId.isEmpty) return;
    try {
      await HiveBoxes.settingsBox.put(_key(shopId), m.key);
    } catch (e) {
      debugPrint('[DishCost] écriture méthode err: $e');
    }
  }
}

/// État d'une fiche technique — ce que l'écran doit dire à l'utilisateur.
class SheetStatus {
  /// Coût théorique d'une portion, `null` si la fiche n'est pas chiffrable.
  final double? cost;

  /// Noms des ingrédients dont la quantité manque ou n'est pas confirmée.
  final List<String> missing;

  /// La fiche ne porte aucun ingrédient — cas distinct de « il en manque » :
  /// ici il n'y a rien à compléter, le plat n'a simplement pas de recette.
  final bool empty;

  const SheetStatus({this.cost, this.missing = const [], this.empty = false});

  bool get isPriceable => cost != null;
}

/// COÛT D'UN PLAT PAR SA FICHE TECHNIQUE.
///
/// Calcul volontairement trivial — `Σ quantité × coût unitaire` — mais isolé
/// dans un service pur pour être vérifiable sans Hive, comme l'est déjà
/// `IngredientAllocationService.allocate`.
///
/// LE COÛT UNITAIRE RETENU est le coût moyen pondéré COURANT de l'ingrédient
/// (`Ingredient.costPerUnit`), pas celui du jour de la vente. C'est ce dont on
/// se sert pour fixer un prix de vente : on veut savoir ce que le plat coûte
/// AUJOURD'HUI, pas ce qu'il coûtait le mois dernier. Corollaire assumé : un
/// réapprovisionnement plus cher renchérit rétroactivement le coût affiché des
/// ventes passées.
class TechnicalSheetService {
  TechnicalSheetService._();

  /// LA RÈGLE, sous forme PURE.
  ///
  /// Rend `null` dès qu'UNE ligne n'est pas chiffrable : une fiche trouée
  /// donnerait un coût sous-évalué et parfaitement crédible, ce qui est pire
  /// qu'un coût absent. Mieux vaut dire « je ne sais pas » que mentir.
  @visibleForTesting
  static double? computeCost(List<({double quantity, int costPerUnit})> lines) {
    if (lines.isEmpty) return null;
    var total = 0.0;
    for (final l in lines) {
      if (l.quantity <= 0 || !l.quantity.isFinite) return null;
      if (l.costPerUnit <= 0) return null;
      total += l.quantity * l.costPerUnit;
    }
    return total;
  }

  /// État de la fiche d'un plat : coût si chiffrable, sinon ce qui manque.
  static SheetStatus statusFor(String shopId, String productId) {
    final lines = RecipeService.forProduct(shopId, productId);
    if (lines.isEmpty) return const SheetStatus(empty: true);

    final missing = <String>[];
    final priceable = <({double quantity, int costPerUnit})>[];
    for (final line in lines) {
      final ing = IngredientService.byId(shopId, line.ingredientId);
      // Ingrédient supprimé depuis : la ligne est orpheline (références
      // logiques, sans FK — cf. hotfix_140). On la signale au lieu de
      // l'ignorer, sinon le plat paraîtrait chiffrable en oubliant un poste.
      if (ing == null) {
        missing.add('ingrédient supprimé');
        continue;
      }
      if (!line.isPriceable || ing.costPerUnit <= 0) {
        missing.add(ing.name);
        continue;
      }
      priceable.add((quantity: line.quantity, costPerUnit: ing.costPerUnit));
    }
    if (missing.isNotEmpty) return SheetStatus(missing: missing);
    return SheetStatus(cost: computeCost(priceable));
  }

  /// Coût théorique par plat, pour les plats DONT LA FICHE EST COMPLÈTE.
  ///
  /// Les autres sont volontairement absents de la map : le consommateur
  /// retombe alors sur le coût matière saisi à la main sur le plat
  /// (`Product.priceBuy`), qui est déjà son repli habituel. Rien n'est
  /// « mélangé » avec la répartition — c'est le même repli qu'un plat sans
  /// ingrédient coché a toujours eu.
  static Map<String, double> costByProduct(
    String shopId,
    Iterable<String> productIds,
  ) {
    final out = <String, double>{};
    for (final pid in productIds) {
      final s = statusFor(shopId, pid);
      final c = s.cost;
      if (c != null && c > 0) out[pid] = c;
    }
    return out;
  }
}

/// FAÇADE — le seul point d'entrée du coût matières.
///
/// Le tableau de bord, le reporting, la fiche plat et le hub Finances appellent
/// ceci et rien d'autre : ils n'ont pas à savoir quelle méthode est active. Le
/// jour où l'on en ajoute une troisième, ils ne bougent pas.
///
/// La sortie garde la forme d'[AllocationResult] dans les deux méthodes — même
/// `costPerDish`, même `forProduct`. En fiche technique, `spendByIngredient`
/// reste renseigné (les achats réels restent une information utile), mais
/// `unallocated` vaut 0 : cette méthode ne répartit rien, elle consomme. Ce que
/// l'on achète sans le consommer reste en stock, ce qui est le comportement
/// correct d'une méthode fondée sur la recette.
class DishCostService {
  DishCostService._();

  static DishCostMethod methodFor(String shopId) =>
      DishCostSettings.forShop(shopId);

  static AllocationResult forPeriod(
    String shopId, {
    required DateTime from,
    required DateTime to,
  }) {
    if (methodFor(shopId) == DishCostMethod.repartition) {
      return IngredientAllocationService.forPeriod(shopId, from: from, to: to);
    }
    return _technical(
      shopId,
      from: from,
      to: to,
      soldByProduct:
          IngredientAllocationService.soldByProduct(shopId, from, to),
    );
  }

  static AllocationResult forSales(
    String shopId, {
    required DateTime from,
    required DateTime to,
    required Map<String, double> soldByProduct,
  }) {
    if (methodFor(shopId) == DishCostMethod.repartition) {
      return IngredientAllocationService.forSales(shopId,
          from: from, to: to, soldByProduct: soldByProduct);
    }
    return _technical(shopId,
        from: from, to: to, soldByProduct: soldByProduct);
  }

  static AllocationResult forMonth(String shopId, DateTime day) => forPeriod(
        shopId,
        from: DateTime(day.year, day.month, 1),
        to: DateTime(day.year, day.month + 1, 0, 23, 59, 59),
      );

  static AllocationResult _technical(
    String shopId, {
    required DateTime from,
    required DateTime to,
    required Map<String, double> soldByProduct,
  }) =>
      AllocationResult(
        costPerDish:
            TechnicalSheetService.costByProduct(shopId, soldByProduct.keys),
        // Les achats réels restent affichés même en fiche technique : c'est
        // eux qu'on compare aux quantités théoriques pour voir si la fiche
        // colle à la réalité du marché.
        spendByIngredient:
            DailyExpenseService.spendByIngredient(shopId, from: from, to: to),
        soldByProduct: soldByProduct,
      );
}
