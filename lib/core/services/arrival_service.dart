import 'package:flutter/foundation.dart';

import '../database/app_database.dart';
import '../storage/hive_boxes.dart';
import '../storage/local_storage_service.dart';
import '../../features/inventaire/domain/entities/product.dart';
import '../../features/inventaire/domain/entities/reception.dart';
import '../../features/inventaire/domain/entities/stock_movement.dart';
import 'arrival_costing_service.dart';
import 'stock_service.dart';

// ═════════════════════════════════════════════════════════════════════════════
// ArrivalService — écrit un bon d'arrivage dans les stocks et les coûts.
//
// Un même bon se saisit désormais depuis DEUX écrans : l'inventaire (bouton
// « Arrivage » et action « Frais » sur une sélection) et la page historique
// (validation d'un brouillon issu d'une commande fournisseur). Sans point
// unique, chaque écran aurait sa propre version de la règle — et elles
// auraient divergé au premier correctif.
//
// Deux natures de bon, cf. `Reception.costOnly` :
//   * ARRIVAGE   — la marchandise entre. Stock += quantité reçue, et le coût
//                  de revient (prix d'achat + part de frais) est absorbé dans
//                  le prix d'achat en moyenne pondérée.
//   * FRAIS SEULS — la marchandise est déjà en rayon. Le stock ne bouge PAS ;
//                  le prix d'achat augmente de la part de frais (addition).
// ═════════════════════════════════════════════════════════════════════════════

class ArrivalService {
  const ArrivalService._();

  /// Applique [reception] : écritures de stock et/ou de coût, puis persiste
  /// le bon en statut `validated` (Hive + Supabase) pour l'historique.
  ///
  /// Les lignes portent déjà leurs quantités dans `receivedQty` (l'appelant
  /// a recueilli la saisie). Le coût de revient est recalculé ici à partir
  /// des frais du bon — l'écran ne décide pas de la répartition.
  ///
  /// Retourne le bon tel qu'il a été archivé, lignes valorisées comprises.
  static Future<Reception> apply(Reception reception) async {
    final now      = DateTime.now();
    final user     = LocalStorageService.getCurrentUser();
    final costOnly = reception.costOnly;

    final costing = ArrivalCostingService.compute(
      lines: reception.items.map((i) => ArrivalLine(
        key:      i.id,
        quantity: i.receivedQty,
        // En frais seuls, aucun prix d'achat n'est ressaisi : seule la part
        // de frais compte, elle s'ajoutera au prix déjà enregistré.
        unitCost: costOnly ? 0 : i.unitCost,
      )).toList(),
      feesTotal: reception.feesTotal,
    );

    final applied = <ReceptionItem>[];
    for (final item in reception.items) {
      final line   = costing.lineFor(item.id);
      final landed = line?.landedUnitCost ?? 0;
      applied.add(item.copyWith(
        status:         ReceptionItemStatus.available,
        landedUnitCost: landed,
      ));

      if (item.receivedQty <= 0 || item.productId == null) continue;

      if (costOnly) {
        final ok = await StockService.applyCostSurcharge(
          shopId:        reception.shopId,
          productId:     item.productId!,
          variantId:     item.variantId ?? '',
          feePerPiece:   costing.feePerPiece,
          piecesCharged: item.receivedQty,
          referenceId:   reception.id,
        );
        // `applyCostSurcharge` travaille sur une variante et rend `false`
        // quand le produit n'en a aucune. Sans ce repli, imputer des frais
        // à un article sans déclinaison ne faisait RIEN, en silence.
        if (!ok) {
          await _surchargeProductWithoutVariant(
            shopId:      reception.shopId,
            productId:   item.productId!,
            feePerPiece: costing.feePerPiece,
          );
        }
      } else {
        await _enterStock(
          shopId:    reception.shopId,
          productId: item.productId!,
          variantId: item.variantId,
          quantity:  item.receivedQty,
          landedUnitCost: landed,
          referenceId: reception.id,
          now: now, userName: user?.name,
        );
      }
    }

    final validated = reception.copyWith(
      status: ReceptionStatus.validated,
      items:  applied,
    );
    await HiveBoxes.receptionsBox.put(validated.id, validated.toMap());
    AppDatabase.bgUpsert('receptions', validated.toMap());
    AppDatabase.notifyProductChange(reception.shopId);
    return validated;
  }

  /// Imputation des frais sur un produit SANS variante : le prix d'achat
  /// du produit lui-même augmente de sa part de frais.
  static Future<void> _surchargeProductWithoutVariant({
    required String shopId,
    required String productId,
    required double feePerPiece,
  }) async {
    if (feePerPiece <= 0) return;
    Product? product;
    for (final p in AppDatabase.getProductsForShop(shopId)) {
      if (p.id == productId) { product = p; break; }
    }
    if (product == null || product.variants.isNotEmpty) return;
    final before = product.priceBuy;
    final after  = ArrivalCostingService.surchargedUnitCost(
        currentUnitCost: before, feePerPiece: feePerPiece);
    await AppDatabase.saveProduct(product.copyWith(priceBuy: after));
    debugPrint('[Arrival] ✅ frais imputés (sans variante) : '
        'priceBuy $before → $after');
  }

  /// Entrée en stock d'une ligne, valorisée à [landedUnitCost] (`0` = pas de
  /// prix saisi → seul le stock bouge, le coût reste intact).
  ///
  /// Passe par `StockService` plutôt que d'écrire le produit à la main :
  /// c'est lui qui tient `stockPhysical` en plus de `stockAvailable`, force
  /// la resynchro du `StockLevel` boutique (sans quoi l'inventaire affiche
  /// l'ancienne valeur) et trace le mouvement.
  static Future<void> _enterStock({
    required String shopId,
    required String productId,
    required String? variantId,
    required int quantity,
    required double landedUnitCost,
    required String referenceId,
    required DateTime now,
    String? userName,
  }) async {
    final products = AppDatabase.getProductsForShop(shopId);
    Product? product;
    for (final p in products) {
      if (p.id == productId) { product = p; break; }
    }

    if (product != null && product.variants.isNotEmpty) {
      final resolved = variantId != null &&
              product.variants.any((v) => v.id == variantId)
          ? variantId
          : mainVariantId(product);
      await StockService.arrivalAvailable(
        shopId:      shopId,
        productId:   productId,
        variantId:   resolved ?? '',
        quantity:    quantity,
        cause:       'supplier_delivery',
        referenceId: referenceId,
        landedUnitCost: landedUnitCost > 0 ? landedUnitCost : null,
      );
      return;
    }

    // Produit sans variante : écriture directe + mouvement.
    final mvt = StockMovement(
      id: 'sm_${now.microsecondsSinceEpoch}_$productId',
      shopId: shopId, productId: productId,
      variantId: variantId, type: StockMovementType.entry,
      quantity: quantity, createdBy: userName, createdAt: now,
    );
    await HiveBoxes.stockMovementsBox.put(mvt.id, mvt.toMap());
    if (product == null) {
      debugPrint('[Arrival] ⚠ produit $productId introuvable : stock non écrit');
      return;
    }
    await AppDatabase.saveProduct(product.copyWith(
      stockQty: product.stockQty + quantity,
      priceBuy: landedUnitCost > 0
          ? ArrivalCostingService.weightedAverageUnitCost(
              currentQty:       product.stockQty,
              currentUnitCost:  product.priceBuy,
              incomingQty:      quantity,
              incomingUnitCost: landedUnitCost)
          : null,
    ));
  }

  /// Variante qui reçoit le stock (et donc le coût) : la principale, sinon
  /// la première. Même règle que `StockService._findVariant`.
  static String? mainVariantId(Product p) {
    if (p.variants.isEmpty) return null;
    final main = p.variants.indexWhere((v) => v.isMain);
    return p.variants[main >= 0 ? main : 0].id;
  }
}
