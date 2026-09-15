import 'package:flutter/foundation.dart' show visibleForTesting;

import 'daily_expense_service.dart';
import 'ingredient_allocation_service.dart';
import 'ingredient_service.dart';
import 'recipe_service.dart';

/// État de la part « fiche technique » du coût d'un plat.
class SheetStatus {
  /// Coût des ingrédients chiffrés à la fiche, pour UNE portion.
  /// `null` = au moins une ligne « fiche » est incomplète, le plat n'est donc
  /// pas chiffrable.
  final double? cost;

  /// Noms des ingrédients « fiche » dont la quantité manque, n'est pas
  /// confirmée, ou dont le coût unitaire est inconnu.
  final List<String> missing;

  /// Le plat ne porte AUCUN ingrédient chiffré à la fiche — cas normal et
  /// distinct de « il en manque » : tout son coût vient de la répartition.
  final bool noSheetLines;

  const SheetStatus({
    this.cost,
    this.missing = const [],
    this.noSheetLines = false,
  });

  bool get isComplete => missing.isEmpty;
}

/// COÛT DES INGRÉDIENTS CHIFFRÉS À LA FICHE TECHNIQUE.
///
/// Ne regarde QUE les lignes de recette dont l'ingrédient porte
/// `cost_method = 'fiche'`. Les autres relèvent de la répartition et sont
/// traitées ailleurs — les deux parts s'additionnent dans [DishCostService].
///
/// LE COÛT UNITAIRE RETENU est le coût moyen pondéré COURANT de l'ingrédient
/// (`Ingredient.costPerUnit`), pas celui du jour de la vente : on veut savoir
/// ce que le plat coûte AUJOURD'HUI, c'est ce qui sert à fixer un prix.
/// Corollaire assumé — un réapprovisionnement plus cher renchérit
/// rétroactivement le coût affiché des ventes passées.
class TechnicalSheetService {
  TechnicalSheetService._();

  /// LA RÈGLE, sous forme PURE.
  ///
  /// Rend `null` dès qu'UNE ligne n'est pas chiffrable : un coût partiel
  /// serait sous-évalué et parfaitement crédible, c'est-à-dire indétectable.
  /// Mieux vaut dire « je ne sais pas » que mentir sur une marge.
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

  /// État de la part « fiche » d'un plat.
  static SheetStatus statusFor(String shopId, String productId) {
    final lines = RecipeService.forProduct(shopId, productId);
    final missing = <String>[];
    final priceable = <({double quantity, int costPerUnit})>[];

    for (final line in lines) {
      final ing = IngredientService.byId(shopId, line.ingredientId);
      // Ingrédient supprimé depuis : la ligne est orpheline (références
      // logiques, sans FK — cf. hotfix_140). On l'ignore plutôt que de la
      // signaler : elle ne relève d'aucune méthode, son ingrédient n'existe
      // plus, et bloquer le plat pour ça punirait une suppression légitime.
      if (ing == null) continue;
      if (!ing.usesTechnicalSheet) continue; // → répartition
      if (!line.isPriceable || ing.costPerUnit <= 0) {
        missing.add(ing.name);
        continue;
      }
      priceable.add((quantity: line.quantity, costPerUnit: ing.costPerUnit));
    }

    if (missing.isNotEmpty) return SheetStatus(missing: missing);
    if (priceable.isEmpty) return const SheetStatus(cost: 0, noSheetLines: true);
    return SheetStatus(cost: computeCost(priceable));
  }

  /// Part « fiche » du coût, par plat. Un plat dont une ligne « fiche » est
  /// incomplète est ABSENT de la map : son coût total est inconnu.
  static Map<String, double> costByProduct(
    String shopId,
    Iterable<String> productIds,
  ) {
    final out = <String, double>{};
    for (final pid in productIds) {
      final c = statusFor(shopId, pid).cost;
      if (c != null) out[pid] = c;
    }
    return out;
  }
}

/// FAÇADE — le seul point d'entrée du coût matières d'un plat.
///
/// Le coût d'un plat est la SOMME de deux parts, chacune calculée par la règle
/// qui sait la mesurer :
///
/// ```
/// coût du plat = part répartie (ingrédients 'repartition')
///              + part fiche    (ingrédients 'fiche')
/// ```
///
/// Ce n'est pas un compromis mou entre deux méthodes : c'est donner à chaque
/// ligne de coût la règle applicable. On pèse le riz ; on ne pèsera jamais
/// 3 g de piment par assiette, et prétendre le contraire ne produirait qu'une
/// fiche jamais remplie.
///
/// Le reporting, les incidents de service et la fiche plat appellent ceci et
/// rien d'autre.
class DishCostService {
  DishCostService._();

  static AllocationResult forPeriod(
    String shopId, {
    required DateTime from,
    required DateTime to,
  }) =>
      forSales(shopId,
          from: from,
          to: to,
          soldByProduct:
              IngredientAllocationService.soldByProduct(shopId, from, to));

  static AllocationResult forMonth(String shopId, DateTime day) => forPeriod(
        shopId,
        from: DateTime(day.year, day.month, 1),
        to: DateTime(day.year, day.month + 1, 0, 23, 59, 59),
      );

  static AllocationResult forSales(
    String shopId, {
    required DateTime from,
    required DateTime to,
    required Map<String, double> soldByProduct,
  }) {
    final sheetIds = _sheetIngredientIds(shopId);

    // ── Part RÉPARTIE ────────────────────────────────────────────────────
    // Achats et liens des ingrédients « fiche » ÉCARTÉS des deux côtés. Ne
    // filtrer que les achats laisserait leurs liens diluer les parts des
    // autres ; ne filtrer que les liens enverrait leurs achats en « non
    // réparti », gonflant un écart qui sert à détecter le gaspillage.
    final spend = DailyExpenseService.spendByIngredient(shopId,
        from: from, to: to);
    final repSpend = <String, int>{
      for (final e in spend.entries)
        if (!sheetIds.contains(e.key)) e.key: e.value,
    };
    final allLinks = IngredientAllocationService.linksByIngredient(shopId);
    final repLinks = <String, List<DishLink>>{
      for (final e in allLinks.entries)
        if (!sheetIds.contains(e.key)) e.key: e.value,
    };
    final repartition = IngredientAllocationService.allocate(
      spendByIngredient: repSpend,
      linksByIngredient: repLinks,
      soldByProduct: soldByProduct,
    );

    // ── Part FICHE ───────────────────────────────────────────────────────
    final sheet = TechnicalSheetService.costByProduct(
        shopId, soldByProduct.keys);

    // ── Somme ────────────────────────────────────────────────────────────
    // Un plat dont la part fiche est INCONNUE est retiré entièrement : rendre
    // sa seule part répartie afficherait un coût amputé de ses ingrédients
    // pesés, plus crédible et plus faux que pas de coût du tout. Il retombe
    // alors sur le coût matière saisi à la main, comme un plat sans recette.
    final costPerDish = <String, double>{};
    for (final pid in soldByProduct.keys) {
      final sheetPart = sheet[pid];
      if (sheetPart == null) continue;
      final repPart = repartition.costPerDish[pid] ?? 0;
      final total = repPart + sheetPart;
      if (total > 0) costPerDish[pid] = total;
    }

    return AllocationResult(
      costPerDish: costPerDish,
      // Achats RÉELS de la période, toutes méthodes confondues : c'est le
      // chiffre de trésorerie, il ne dépend pas de la façon dont on l'impute.
      spendByIngredient: spend,
      unallocated: repartition.unallocated,
      soldByProduct: soldByProduct,
    );
  }

  /// Plats dont la part « fiche » est incomplète, avec ce qui leur manque.
  /// Sert aux écrans à dire POURQUOI un plat n'affiche pas de coût.
  static Map<String, List<String>> incompleteSheets(
    String shopId,
    Iterable<String> productIds,
  ) {
    final out = <String, List<String>>{};
    for (final pid in productIds) {
      final s = TechnicalSheetService.statusFor(shopId, pid);
      if (!s.isComplete) out[pid] = s.missing;
    }
    return out;
  }

  static Set<String> _sheetIngredientIds(String shopId) => {
        for (final i in IngredientService.forShop(shopId))
          if (i.usesTechnicalSheet) i.id,
      };
}
