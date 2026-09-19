import 'package:flutter/foundation.dart' show debugPrint;

import '../../features/restaurant/domain/entities/recipe_ingredient.dart';
import '../storage/hive_boxes.dart';
import 'daily_expense_service.dart';
import 'recipe_service.dart';

/// Un lien plat ↔ ingrédient, réduit à ce dont la répartition a besoin.
typedef DishLink = ({String productId, double weight});

/// Résultat d'une répartition sur une période.
class AllocationResult {
  /// Coût matières d'UN plat vendu, par produit (FCFA).
  final Map<String, double> costPerDish;

  /// Ce que chaque ingrédient a coûté sur la période (FCFA).
  final Map<String, int> spendByIngredient;

  /// Achats d'ingrédients que RIEN n'a pu absorber (FCFA) : aucun plat les
  /// contenant n'a été vendu sur la période.
  ///
  /// Ce n'est pas une erreur — c'est un stock constitué d'avance, ou un
  /// ingrédient dont on a oublié de cocher les plats. Ces francs restent dans
  /// le food cost global, ils ne sont simplement imputables à aucune assiette.
  final int unallocated;

  /// Quantités vendues par produit sur la période.
  final Map<String, double> soldByProduct;

  /// Assiettes PERDUES par produit sur la période (hotfix_179). Elles ont
  /// compté comme des parts de la répartition, au même coût unitaire que les
  /// assiettes vendues.
  final Map<String, double> wastedByProduct;

  /// Montants retirés des achats de chaque ingrédient pour des manques
  /// d'inventaire, APRÈS plafonnement à ces achats (FCFA).
  final Map<String, int> withdrawnByIngredient;

  const AllocationResult({
    this.costPerDish = const {},
    this.spendByIngredient = const {},
    this.unallocated = 0,
    this.soldByProduct = const {},
    this.wastedByProduct = const {},
    this.withdrawnByIngredient = const {},
  });

  /// Coût matières d'un plat, 0 si rien ne lui a été imputé.
  double forProduct(String productId) => costPerDish[productId] ?? 0;

  /// Total réparti sur les ventes de la période.
  ///
  /// Par construction, `réparti + non réparti == total des achats rattachés` :
  /// la répartition ne crée ni ne perd d'argent.
  double get allocated {
    var sum = 0.0;
    for (final e in costPerDish.entries) {
      sum += e.value * (soldByProduct[e.key] ?? 0);
    }
    return sum;
  }

  bool get isEmpty => costPerDish.isEmpty;
}

/// RÉPARTITION DU COÛT DES INGRÉDIENTS AU PRORATA DES VENTES.
///
/// Le principe, et pourquoi il existe : personne ne pèse 125 g de poulet par
/// assiette en plein service. On ne demande donc AUCUNE quantité. On demande
/// seulement quels plats contiennent quel ingrédient — une case à cocher — et
/// l'app fait le reste :
///
/// ```
/// Poulet acheté en juillet ......... 140 000 F
/// Plats qui en contiennent :
///    Ndolé poulet    120 vendus  × 1
///    Riz sauté        80 vendus  × 1
///                    ─────────
///                    200 parts   →  700 F de poulet par plat
/// ```
///
/// Le poids de portion ([RecipeIngredient.portionWeight]) permet de dire qu'un
/// plat est plus généreux qu'un autre — sans jamais sortir la balance.
///
/// CE QUE CETTE MÉTHODE NE PEUT PAS FAIRE, et il faut le savoir :
///   * elle ne détecte aucun sur-dosage — il n'existe pas de quantité
///     théorique à laquelle comparer la consommation réelle ;
///   * le coût d'un plat BOUGE d'une période à l'autre au gré des achats : un
///     mois où l'on achète beaucoup de poulet, le Ndolé paraît plus cher. Elle
///     est fidèle à la trésorerie, pas à la recette.
///
/// Service statique et SANS ÉTAT : il lit Hive et rend un [AllocationResult].
class IngredientAllocationService {
  IngredientAllocationService._();

  /// Répartition sur `[from, to]` (bornes incluses).
  static AllocationResult forPeriod(
    String shopId, {
    required DateTime from,
    required DateTime to,
  }) {
    final spend = DailyExpenseService.spendByIngredient(shopId,
        from: from, to: to);
    if (spend.isEmpty) {
      return AllocationResult(soldByProduct: soldByProduct(shopId, from, to));
    }
    final sold = soldByProduct(shopId, from, to);
    final links = linksByIngredient(shopId);
    return allocate(
      spendByIngredient: spend,
      linksByIngredient: links,
      soldByProduct: sold,
    );
  }

  /// Répartition à partir de ventes DÉJÀ COMPTÉES.
  ///
  /// Pour les appelants qui parcourent de toute façon les commandes — le
  /// tableau de bord, notamment. Sans cette porte d'entrée, ils payaient un
  /// second balayage complet de la boîte des commandes rien que pour obtenir
  /// un décompte qu'ils venaient d'établir.
  static AllocationResult forSales(
    String shopId, {
    required DateTime from,
    required DateTime to,
    required Map<String, double> soldByProduct,
  }) {
    final spend = DailyExpenseService.spendByIngredient(shopId,
        from: from, to: to);
    if (spend.isEmpty) {
      return AllocationResult(soldByProduct: soldByProduct);
    }
    return allocate(
      spendByIngredient: spend,
      linksByIngredient: linksByIngredient(shopId),
      soldByProduct: soldByProduct,
    );
  }

  /// Répartition du mois de [day] — la maille sur laquelle un gérant raisonne.
  static AllocationResult forMonth(String shopId, DateTime day) => forPeriod(
        shopId,
        from: DateTime(day.year, day.month, 1),
        to: DateTime(day.year, day.month + 1, 0, 23, 59, 59),
      );

  /// LA RÈGLE, sous forme PURE — aucun accès Hive, donc vérifiable directement.
  ///
  /// Publique (et non `@visibleForTesting`) depuis que `DishCostService`
  /// l'appelle avec des cartes FILTRÉES : seuls les ingrédients chiffrés à la
  /// répartition y entrent, ceux en fiche technique sont écartés en amont.
  ///
  /// Pour chaque ingrédient : son coût est divisé par la somme des parts
  /// vendues (quantité × poids de portion), puis chaque plat en reçoit sa part.
  ///
  /// Un ingrédient dont aucun plat n'a été vendu ne peut rien financer : son
  /// coût part dans [AllocationResult.unallocated] plutôt que d'être écrasé sur
  /// un plat au hasard ou de disparaître.
  static AllocationResult allocate({
    required Map<String, int> spendByIngredient,
    required Map<String, List<DishLink>> linksByIngredient,
    required Map<String, double> soldByProduct,
  }) {
    final costPerDish = <String, double>{};
    var unallocated = 0;

    for (final entry in spendByIngredient.entries) {
      final spend = entry.value;
      if (spend <= 0) continue;
      final links = linksByIngredient[entry.key] ?? const <DishLink>[];

      // Dénominateur = total des parts vendues qui portent cet ingrédient.
      var parts = 0.0;
      for (final l in links) {
        final qty = soldByProduct[l.productId] ?? 0;
        if (qty <= 0 || l.weight <= 0) continue;
        parts += qty * l.weight;
      }
      if (parts <= 0) {
        unallocated += spend;
        continue;
      }

      final perPart = spend / parts;
      for (final l in links) {
        if (l.weight <= 0) continue;
        if ((soldByProduct[l.productId] ?? 0) <= 0) continue;
        costPerDish[l.productId] =
            (costPerDish[l.productId] ?? 0) + perPart * l.weight;
      }
    }

    return AllocationResult(
      costPerDish: costPerDish,
      spendByIngredient: spendByIngredient,
      unallocated: unallocated,
      soldByProduct: soldByProduct,
    );
  }

  /// Plats portant chaque ingrédient — `ingredientId → [(plat, poids)]`.
  ///
  /// Lu en UNE passe sur la boîte des liens : la boucle de répartition ne doit
  /// pas la rescanner pour chaque ingrédient.
  static Map<String, List<DishLink>> linksByIngredient(String shopId) {
    final out = <String, List<DishLink>>{};
    try {
      for (final line in RecipeService.forShop(shopId)) {
        // Un plat supprimé du catalogue ne se vend plus : il ne fausse donc
        // pas le dénominateur (sa quantité vendue sera nulle). On le garde
        // quand même dans la liste, c'est `soldByProduct` qui tranche.
        (out[line.ingredientId] ??= []).add(
          (productId: line.productId, weight: line.effectiveWeight),
        );
      }
    } catch (e) {
      debugPrint('[Allocation] liens err: $e');
    }
    return out;
  }

  /// Quantités vendues par produit sur la période (commandes CLÔTURÉES).
  ///
  /// Mêmes bornes que tout le reste du reporting : une commande en cours n'a
  /// pas encore consommé de matière au sens comptable.
  static Map<String, double> soldByProduct(
      String shopId, DateTime from, DateTime to) {
    final out = <String, double>{};
    try {
      for (final raw in HiveBoxes.ordersBox.values) {
        final o = Map<String, dynamic>.from(raw);
        if (o['shop_id']?.toString() != shopId) continue;
        final deleted = o['deleted_at'];
        if (deleted != null && deleted.toString().isNotEmpty) continue;
        if (o['status']?.toString() != 'completed') continue;

        final rawDate = o['completed_at'] ?? o['created_at'];
        final date = rawDate == null
            ? null
            : DateTime.tryParse(rawDate.toString())?.toLocal();
        if (date == null) continue;
        if (date.isBefore(from) || date.isAfter(to)) continue;

        for (final rawItem in (o['items'] as List? ?? [])) {
          if (rawItem is! Map) continue;
          final it = Map<String, dynamic>.from(rawItem);
          final qty = ((it['quantity'] ?? it['qty']) as num?)?.toDouble() ?? 0;
          if (qty <= 0) continue;
          final pid = it['product_id']?.toString() ?? '';
          if (pid.isNotEmpty) out[pid] = (out[pid] ?? 0) + qty;

          // ACCOMPAGNEMENTS — une option adossée à un plat (« Sauce
          // d'arachide », « Poulet ») a été cuisinée autant de fois que la
          // ligne a été vendue. Sans ce comptage, ses ingrédients n'auraient
          // aucun plat sur lequel se répartir : leur coût partirait en « non
          // réparti » et « Riz sauce arachide poulet » afficherait le prix du
          // riz seul.
          for (final rawMod in (it['modifiers'] as List? ?? [])) {
            if (rawMod is! Map) continue;
            final mid = rawMod['product_id']?.toString() ?? '';
            if (mid.isEmpty) continue;
            out[mid] = (out[mid] ?? 0) + qty;
          }
        }
      }
    } catch (e) {
      debugPrint('[Allocation] ventes err: $e');
    }
    return out;
  }
}
