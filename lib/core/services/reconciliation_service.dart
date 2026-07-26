import 'package:flutter/foundation.dart' show debugPrint;

import 'ingredient_service.dart';
import 'loss_service.dart';
import 'stock_item_service.dart';

/// Un article comptable — vue unifiée d'un `Ingredient` et d'un `StockItem`.
///
/// La réconciliation d'inventaire couvre les DEUX : une caisse de boissons se
/// compte exactement comme un sac de riz. Les deux entités restent séparées en
/// base (usages différents : recette vs vente directe), seul le comptage les
/// réunit.
class CountableItem {
  final String id;
  final String name;
  final String unit;

  /// Stock théorique : ce que l'application croit avoir en réserve.
  final double theoretical;

  /// Coût d'achat unitaire (FCFA entier) — base du chiffrage de l'écart.
  final int costPerUnit;

  /// `true` = ingrédient, `false` = article de stock. Détermine le service
  /// qui portera la correction.
  final bool isIngredient;

  const CountableItem({
    required this.id,
    required this.name,
    required this.unit,
    required this.theoretical,
    required this.costPerUnit,
    required this.isIngredient,
  });

  /// Clé unique tous types confondus — un ingrédient et un article de stock
  /// peuvent théoriquement porter le même id.
  String get key => '${isIngredient ? 'ing' : 'si'}:$id';
}

/// Écart constaté entre le stock théorique et le stock réellement compté.
class StockVariance {
  final CountableItem item;

  /// Stock réel compté en réserve. Fait toujours foi.
  final double actual;

  const StockVariance({required this.item, required this.actual});

  /// Négatif = il manque de la marchandise, positif = il en reste plus que
  /// prévu.
  double get variance => actual - item.theoretical;

  /// Manque : marchandise partie sans vente enregistrée (sur-dosage en
  /// cuisine, casse non déclarée, vol, erreur de saisie).
  bool get isShortage => variance < 0;

  /// Surplus : il reste plus que prévu (sous-dosage, recette trop généreuse
  /// sur le papier).
  bool get isSurplus => variance > 0;

  /// Valorisation de l'écart en FCFA, toujours positive.
  int get financialImpact => (variance.abs() * item.costPerUnit).round();

  /// Libellé métier de l'écart, affiché dans le récapitulatif.
  String get label => isShortage
      ? 'Perte / sur-dosage'
      : (isSurplus ? 'Sous-dosage' : 'Conforme');
}

/// Ce qu'une variance déclenche : correction de stock et/ou perte.
class ReconciliationDecision {
  /// Le stock doit être réécrit à la valeur comptée.
  final bool adjustStock;

  /// Montant de la perte à enregistrer (0 = aucune).
  final int lossAmount;

  const ReconciliationDecision({
    required this.adjustStock,
    required this.lossAmount,
  });

  bool get createsLoss => lossAmount > 0;
}

/// Bilan d'une réconciliation appliquée.
class ReconciliationOutcome {
  /// Nombre d'articles dont le stock a effectivement été corrigé.
  final int adjusted;

  /// Nombre de pertes créées.
  final int lossesCount;

  /// Total des pertes créées (FCFA).
  final int lossTotal;

  const ReconciliationOutcome({
    this.adjusted = 0,
    this.lossesCount = 0,
    this.lossTotal = 0,
  });
}

/// Réconciliation d'inventaire (module finances — Lot 2).
///
/// Compare le stock théorique au stock réellement compté, corrige le stock et
/// enregistre l'écart en perte via [LossService] — point d'entrée unique des
/// pertes, saisie manuelle comprise.
///
/// Règles (décision D4) :
///   * écart nul → AUCUNE écriture (ni stock, ni perte) ;
///   * le stock compté fait TOUJOURS foi, perte ou pas ;
///   * seul un MANQUE crée une perte. Un surplus n'en crée pas : `losses.amount`
///     est un entier positif, une perte négative fausserait `LossService.total`
///     et tous les cumuls du bilan ;
///   * un manque dont le coût unitaire n'est pas renseigné ne crée pas de perte
///     à 0 F — la ligne serait du bruit dans l'onglet Pertes.
class ReconciliationService {
  ReconciliationService._();

  /// Catégorie dédiée (CHECK SQL étendu par hotfix_141) : les écarts
  /// d'inventaire ne se mélangent pas aux pertes « autre ».
  static const String lossCategory = 'ecart_inventaire';

  /// Provenance inscrite sur la perte — format documenté par `Loss.origin`.
  static String originFor(String itemName) => 'réconciliation: $itemName';

  /// Tout ce qui se compte dans la boutique : ingrédients puis articles de
  /// stock, chaque groupe trié par nom (ordre déjà garanti par les services).
  static List<CountableItem> countableItems(String shopId) {
    final items = <CountableItem>[];
    for (final i in IngredientService.forShop(shopId)) {
      items.add(CountableItem(
        id: i.id,
        name: i.name,
        unit: i.unit,
        theoretical: i.quantity,
        costPerUnit: i.costPerUnit,
        isIngredient: true,
      ));
    }
    for (final s in StockItemService.forShop(shopId)) {
      items.add(CountableItem(
        id: s.id,
        name: s.name,
        unit: s.unit,
        theoretical: s.quantity,
        costPerUnit: s.costPerUnit,
        isIngredient: false,
      ));
    }
    return items;
  }

  /// Règle D4 sous forme PURE — aucune écriture, aucun accès Hive. C'est la
  /// seule définition de « ce que produit un écart » : [apply] s'y conforme,
  /// et les tests la vérifient directement.
  static ReconciliationDecision decide(StockVariance v) {
    if (v.variance == 0) {
      return const ReconciliationDecision(adjustStock: false, lossAmount: 0);
    }
    return ReconciliationDecision(
      adjustStock: true,
      lossAmount: v.isShortage ? v.financialImpact : 0,
    );
  }

  /// Applique une série d'écarts : corrige les stocks et enregistre les pertes.
  ///
  /// [variances] ne doit contenir QUE les articles réellement comptés — un
  /// article non compté n'est pas un écart de zéro, il est absent de la liste.
  static Future<ReconciliationOutcome> apply({
    required String shopId,
    required List<StockVariance> variances,
    String? declaredBy,
  }) async {
    var adjusted = 0, lossesCount = 0, lossTotal = 0;

    for (final v in variances) {
      final decision = decide(v);
      if (!decision.adjustStock) continue;

      // Le stock d'abord : c'est la correction attendue par l'utilisateur,
      // elle ne doit pas dépendre du succès de l'écriture de la perte.
      if (!await _writeQuantity(shopId, v)) continue;
      adjusted++;

      if (!decision.createsLoss) continue;
      try {
        await LossService.record(
          shopId: shopId,
          description: '${v.item.name} — manque '
              '${_fmt(v.variance.abs())} ${v.item.unit}',
          amount: decision.lossAmount,
          category: lossCategory,
          origin: originFor(v.item.name),
          declaredBy: declaredBy,
        );
        lossesCount++;
        lossTotal += decision.lossAmount;
      } catch (e) {
        // Le stock est déjà corrigé : on ne le rembobine pas pour une perte
        // non écrite, l'inventaire physique reste juste.
        debugPrint('[Reconcile] perte non enregistrée (${v.item.name}): $e');
      }
    }

    return ReconciliationOutcome(
      adjusted: adjusted,
      lossesCount: lossesCount,
      lossTotal: lossTotal,
    );
  }

  /// Réécrit la quantité à la valeur comptée. Relit l'entité juste avant
  /// l'écriture : entre le comptage et la validation, un autre appareil a pu
  /// changer le coût ou le seuil, et un `copyWith` sur un objet périmé les
  /// écraserait. Retourne `false` si l'article a disparu entre-temps.
  static Future<bool> _writeQuantity(String shopId, StockVariance v) async {
    try {
      if (v.item.isIngredient) {
        final fresh = IngredientService.byId(shopId, v.item.id);
        if (fresh == null) return false;
        await IngredientService.update(fresh.copyWith(quantity: v.actual));
      } else {
        final fresh = StockItemService.byId(shopId, v.item.id);
        if (fresh == null) return false;
        await StockItemService.update(fresh.copyWith(quantity: v.actual));
      }
      return true;
    } catch (e) {
      debugPrint('[Reconcile] correction stock err (${v.item.name}): $e');
      return false;
    }
  }

  /// Quantité lisible, sans « .0 » superflu.
  static String _fmt(double v) =>
      v == v.truncateToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
}
