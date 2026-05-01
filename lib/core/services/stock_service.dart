import 'package:flutter/foundation.dart';
import '../storage/hive_boxes.dart';
import '../storage/local_storage_service.dart';
import '../database/app_database.dart';
import '../../features/inventaire/domain/entities/product.dart';
import '../../features/inventaire/domain/entities/stock_movement.dart';
import '../../features/inventaire/domain/entities/incident.dart';
import '../../features/inventaire/domain/entities/stock_location.dart';
import '../../features/inventaire/domain/entities/stock_level.dart';
import '../../features/inventaire/domain/entities/stock_transfer.dart';
import 'activity_log_service.dart';

/// Erreur dédiée : tentative de vente avec un stock insuffisant
/// (ou variante introuvable). Throwée par `StockService.sale` et
/// `StockService.saleFromLocation` au lieu de retourner false en silence.
class InsufficientStockException implements Exception {
  final String message;
  /// Quantité demandée par l'opération qui a échoué.
  final int requested;
  /// Stock effectivement disponible au moment du throw.
  final int available;
  final String? variantId;
  const InsufficientStockException({
    required this.message,
    required this.requested,
    required this.available,
    this.variantId,
  });
  @override
  String toString() => 'InsufficientStockException: $message';
}

/// Service centralisé pour toutes les opérations de stock.
/// Chaque opération :
///   1. Vérifie les pré-conditions (stock_available >= 0)
///   2. Met à jour la variante (4 champs)
///   3. Propage le stock global du produit
///   4. Crée un log inaltérable dans stock_movements
///   5. Notifie les providers
class StockService {

  // ════════════════════════════════════════════════════════════════════════════
  // 1. ARRIVÉE AVAILABLE — stock_physical + qty, stock_available + qty
  // ════════════════════════════════════════════════════════════════════════════

  static Future<void> arrivalAvailable({
    required String shopId,
    required String productId,
    required String variantId,
    required int quantity,
    required String cause,
    String? notes,
    String? referenceId,
  }) async {
    final result = _findVariant(shopId, productId, variantId);
    if (result == null) {
      debugPrint('[Stock] ❌ arrivalAvailable: variante introuvable '
          'shopId=$shopId productId=$productId variantId=$variantId');
      return;
    }
    final (product, vIdx) = result;
    final v = product.variants[vIdx];

    final beforeAvail = v.stockAvailable;
    final beforePhys  = v.stockPhysical;

    final updated = v.copyWith(
      stockAvailable: v.stockAvailable + quantity,
      stockPhysical:  v.stockPhysical + quantity,
    );

    await _saveVariant(product, vIdx, updated, shopId);
    debugPrint('[Stock] ✅ arrivalAvailable +$quantity : '
        'available $beforeAvail → ${updated.stockAvailable}, '
        'physical $beforePhys → ${updated.stockPhysical}');
    _log(shopId: shopId, productId: productId, variantId: variantId,
      type: 'arrival_available', quantity: quantity,
      beforeAvail: beforeAvail, afterAvail: updated.stockAvailable,
      beforePhys: beforePhys, afterPhys: updated.stockPhysical,
      cause: cause, notes: notes, referenceId: referenceId);
    // Audit "métier" pour l'historique de la boutique.
    await ActivityLogService.log(
      action:      'stock_arrival',
      targetType:  'product',
      targetId:    productId,
      targetLabel: '${product.name} — ${updated.name}',
      shopId:      shopId,
      details: {
        'quantity': quantity,
        'cause':    cause,
        if ((notes ?? '').isNotEmpty) 'notes': notes,
        if ((referenceId ?? '').isNotEmpty) 'reference': referenceId,
      },
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // 2. INCIDENT SUR STOCK EXISTANT — available − qty, blocked + qty
  //    physical inchangé (les unités sont toujours physiquement là)
  //    + création incident automatique
  // ════════════════════════════════════════════════════════════════════════════

  /// Transfère des unités de available vers blocked pour déclarer un incident.
  /// Retourne false si available < quantity.
  static Future<bool> blockExisting({
    required String shopId,
    required String productId,
    required String variantId,
    required int quantity,
    required String status, // damaged, defective, to_inspect
    required String cause,
    required String productName,
    String? notes,
    String? referenceId,
  }) async {
    final result = _findVariant(shopId, productId, variantId);
    if (result == null) return false;
    final (product, vIdx) = result;
    final v = product.variants[vIdx];

    if (v.stockAvailable < quantity) {
      debugPrint('[Stock] BLOQUÉ : blockExisting $quantity > available ${v.stockAvailable}');
      return false;
    }

    final beforeAvail   = v.stockAvailable;
    final beforeBlocked = v.stockBlocked;

    final updated = v.copyWith(
      stockAvailable: v.stockAvailable - quantity,
      stockBlocked:   v.stockBlocked + quantity,
    );

    await _saveVariant(product, vIdx, updated, shopId);

    // Créer l'incident
    final now  = DateTime.now();
    final user = LocalStorageService.getCurrentUser();
    final incType = status == 'damaged' ? IncidentType.scrapped
        : status == 'defective' ? IncidentType.inRepair
        : IncidentType.scrapped;
    final incident = Incident(
      id: 'inc_${now.microsecondsSinceEpoch}',
      shopId: shopId, productId: productId, variantId: variantId,
      productName: productName, type: incType, quantity: quantity,
      notes: 'Incident $status — $cause${notes != null ? ' — $notes' : ''}',
      createdBy: user?.name, createdAt: now,
    );
    HiveBoxes.incidentsBox.put(incident.id, incident.toMap());

    _log(shopId: shopId, productId: productId, variantId: variantId,
      type: 'block_existing', quantity: quantity, status: status,
      beforeAvail: beforeAvail, afterAvail: updated.stockAvailable,
      beforeBlocked: beforeBlocked, afterBlocked: updated.stockBlocked,
      cause: cause, notes: notes, referenceId: referenceId);
    await ActivityLogService.log(
      action:      'stock_incident',
      targetType:  'product',
      targetId:    productId,
      targetLabel: '$productName — ${updated.name}',
      shopId:      shopId,
      details: {
        'status':   status,
        'quantity': quantity,
        'cause':    cause,
        if ((notes ?? '').isNotEmpty) 'notes': notes,
        if ((referenceId ?? '').isNotEmpty) 'reference': referenceId,
      },
    );
    return true;
  }

  // ════════════════════════════════════════════════════════════════════════════
  // 3. VENTE — stock_available − qty, stock_physical − qty
  // ════════════════════════════════════════════════════════════════════════════

  /// Décrémente le stock d'une variante pour une vente.
  /// Throw [InsufficientStockException] si la variante est introuvable ou
  /// si le stock disponible est inférieur à `quantity` (la transaction est
  /// alors avortée AVANT toute écriture, garantissant l'intégrité).
  static Future<void> sale({
    required String shopId,
    required String productId,
    required String variantId,
    required int quantity,
    String? orderId,
  }) async {
    final result = _findVariant(shopId, productId, variantId);
    if (result == null) {
      throw InsufficientStockException(
        message:   'Variante introuvable (productId=$productId, '
                   'variantId=$variantId, shop=$shopId).',
        requested: quantity,
        available: 0,
        variantId: variantId,
      );
    }
    final (product, vIdx) = result;
    final v = product.variants[vIdx];

    if (v.stockAvailable < quantity) {
      debugPrint('[Stock] BLOQUÉ : vente $quantity > available '
          '${v.stockAvailable}');
      throw InsufficientStockException(
        message:   'Stock insuffisant pour "${product.name} — ${v.name}" '
                   '(disponible : ${v.stockAvailable}, demandé : $quantity).',
        requested: quantity,
        available: v.stockAvailable,
        variantId: variantId,
      );
    }

    final beforeAvail = v.stockAvailable;
    final beforePhys  = v.stockPhysical;

    final updated = v.copyWith(
      stockAvailable: v.stockAvailable - quantity,
      stockPhysical:  v.stockPhysical - quantity,
    );

    await _saveVariant(product, vIdx, updated, shopId);
    _log(shopId: shopId, productId: productId, variantId: variantId,
      type: 'sale', quantity: -quantity,
      beforeAvail: beforeAvail, afterAvail: updated.stockAvailable,
      beforePhys: beforePhys, afterPhys: updated.stockPhysical,
      referenceId: orderId);
  }

  // ════════════════════════════════════════════════════════════════════════════
  // 3c. VENTE DEPUIS UN PARTENAIRE — stock partenaire − qty
  // ════════════════════════════════════════════════════════════════════════════

  /// Décrémente le stock d'un partenaire (ou warehouse) pour une vente dont
  /// la livraison est assurée depuis ce point. Ne touche PAS à la variante :
  /// seuls les StockLevel à la location concernée sont modifiés.
  /// Throw [InsufficientStockException] si le StockLevel est absent ou
  /// si le stock disponible à la location est insuffisant.
  static Future<void> saleFromLocation({
    required String locationId,
    required String variantId,
    required int quantity,
    required String shopId,       // boutique qui saisit la commande (logs)
    String? productId,
    String? orderId,
  }) async {
    final lvl = AppDatabase.getStockLevel(variantId, locationId);
    if (lvl == null) {
      debugPrint('[Stock] saleFromLocation BLOQUÉ : StockLevel absent '
          'pour variant=$variantId loc=$locationId');
      throw InsufficientStockException(
        message:   'Aucun stock enregistré à la location $locationId pour '
                   'la variante $variantId.',
        requested: quantity,
        available: 0,
        variantId: variantId,
      );
    }
    if (lvl.stockAvailable < quantity) {
      debugPrint('[Stock] saleFromLocation BLOQUÉ : '
          'available=${lvl.stockAvailable} < qty=$quantity');
      throw InsufficientStockException(
        message:   'Stock insuffisant à la location $locationId '
                   '(disponible : ${lvl.stockAvailable}, demandé : $quantity).',
        requested: quantity,
        available: lvl.stockAvailable,
        variantId: variantId,
      );
    }
    final beforeAvail = lvl.stockAvailable;
    final beforePhys  = lvl.stockPhysical;
    final updated = lvl.copyWith(
      stockAvailable: lvl.stockAvailable - quantity,
      stockPhysical:  lvl.stockPhysical  - quantity,
      updatedAt:      DateTime.now(),
    );
    await AppDatabase.saveStockLevel(updated);

    _log(
      shopId:      shopId,
      productId:   productId ?? '',
      variantId:   variantId,
      type:        'sale',
      quantity:    -quantity,
      beforeAvail: beforeAvail,
      afterAvail:  updated.stockAvailable,
      beforePhys:  beforePhys,
      afterPhys:   updated.stockPhysical,
      referenceId: orderId,
      notes:       'Vente livrée depuis une location distincte',
    );
  }

  /// Inverse d'une vente livrée par une location (annulation). Restaure le
  /// StockLevel à la location donnée.
  static Future<void> reverseSaleFromLocation({
    required String locationId,
    required String variantId,
    required int quantity,
    required String shopId,
    String? productId,
    String? orderId,
    String? reason,
  }) async {
    final lvl = AppDatabase.getStockLevel(variantId, locationId);
    if (lvl == null) return;
    final beforeAvail = lvl.stockAvailable;
    final beforePhys  = lvl.stockPhysical;
    final updated = lvl.copyWith(
      stockAvailable: lvl.stockAvailable + quantity,
      stockPhysical:  lvl.stockPhysical  + quantity,
      updatedAt:      DateTime.now(),
    );
    await AppDatabase.saveStockLevel(updated);
    _log(
      shopId:      shopId,
      productId:   productId ?? '',
      variantId:   variantId,
      type:        'sale',
      quantity:    quantity,
      beforeAvail: beforeAvail,
      afterAvail:  updated.stockAvailable,
      beforePhys:  beforePhys,
      afterPhys:   updated.stockPhysical,
      referenceId: orderId,
      notes:       reason ?? 'Annulation vente livrée par location distincte',
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // 3b. ANNULATION DE VENTE — restauration stock (completed → autre statut)
  // ════════════════════════════════════════════════════════════════════════════

  /// Inverse une vente : stock_available + qty, stock_physical + qty.
  /// Appelé quand le statut d'une commande passe de `completed` à un autre
  /// statut (`scheduled`, `cancelled`, `refused`, `refunded`). Crée un log
  /// `type: 'sale'` avec quantity positive + notes explicatives.
  static Future<void> reverseSale({
    required String shopId,
    required String productId,
    required String variantId,
    required int quantity,
    String? orderId,
    String? reason,
  }) async {
    final result = _findVariant(shopId, productId, variantId);
    if (result == null) return;
    final (product, vIdx) = result;
    final v = product.variants[vIdx];

    final beforeAvail = v.stockAvailable;
    final beforePhys  = v.stockPhysical;

    final updated = v.copyWith(
      stockAvailable: v.stockAvailable + quantity,
      stockPhysical:  v.stockPhysical  + quantity,
    );

    await _saveVariant(product, vIdx, updated, shopId);
    _log(
      shopId:      shopId,
      productId:   productId,
      variantId:   variantId,
      type:        'sale',           // type existant autorisé
      quantity:    quantity,         // positif = restauration
      beforeAvail: beforeAvail,
      afterAvail:  updated.stockAvailable,
      beforePhys:  beforePhys,
      afterPhys:   updated.stockPhysical,
      referenceId: orderId,
      notes:       reason ?? 'Annulation vente (commande reprogrammée)',
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // 4. RÉSOLUTION INCIDENT
  // ════════════════════════════════════════════════════════════════════════════

  /// Réparation réussie ou prix réduit : blocked → available
  static Future<void> incidentToAvailable({
    required String shopId,
    required String productId,
    required String variantId,
    required int quantity,
    required String resolution, // repair_success, discounted
    String? incidentId,
  }) async {
    final result = _findVariant(shopId, productId, variantId);
    if (result == null) return;
    final (product, vIdx) = result;
    final v = product.variants[vIdx];

    final updated = v.copyWith(
      stockBlocked:   (v.stockBlocked - quantity).clamp(0, 999999),
      stockAvailable: v.stockAvailable + quantity,
    );

    await _saveVariant(product, vIdx, updated, shopId);
    _log(shopId: shopId, productId: productId, variantId: variantId,
      type: 'incident_resolved', quantity: quantity,
      beforeBlocked: v.stockBlocked, afterBlocked: updated.stockBlocked,
      beforeAvail: v.stockAvailable, afterAvail: updated.stockAvailable,
      cause: resolution, referenceId: incidentId);
  }

  /// Rebut ou retour fournisseur : blocked − qty, physical − qty
  static Future<void> incidentRemove({
    required String shopId,
    required String productId,
    required String variantId,
    required int quantity,
    required String resolution, // scrapped, return_supplier
    String? incidentId,
  }) async {
    final result = _findVariant(shopId, productId, variantId);
    if (result == null) return;
    final (product, vIdx) = result;
    final v = product.variants[vIdx];

    final updated = v.copyWith(
      stockBlocked:  (v.stockBlocked - quantity).clamp(0, 999999),
      stockPhysical: (v.stockPhysical - quantity).clamp(0, 999999),
    );

    await _saveVariant(product, vIdx, updated, shopId);
    _log(shopId: shopId, productId: productId, variantId: variantId,
      type: 'incident_resolved', quantity: -quantity,
      beforeBlocked: v.stockBlocked, afterBlocked: updated.stockBlocked,
      beforePhys: v.stockPhysical, afterPhys: updated.stockPhysical,
      cause: resolution, referenceId: incidentId);
  }

  // ════════════════════════════════════════════════════════════════════════════
  // 5. RETOUR CLIENT
  // ════════════════════════════════════════════════════════════════════════════

  /// Bon état : stock_available + qty, stock_physical + qty
  static Future<void> returnGood({
    required String shopId,
    required String productId,
    required String variantId,
    required int quantity,
    String? orderId,
  }) async {
    final result = _findVariant(shopId, productId, variantId);
    if (result == null) return;
    final (product, vIdx) = result;
    final v = product.variants[vIdx];

    final updated = v.copyWith(
      stockAvailable: v.stockAvailable + quantity,
      stockPhysical:  v.stockPhysical + quantity,
    );

    await _saveVariant(product, vIdx, updated, shopId);
    _log(shopId: shopId, productId: productId, variantId: variantId,
      type: 'return_client_good', quantity: quantity,
      beforeAvail: v.stockAvailable, afterAvail: updated.stockAvailable,
      beforePhys: v.stockPhysical, afterPhys: updated.stockPhysical,
      referenceId: orderId);
  }

  /// Défectueux : stock_blocked + qty, stock_physical + qty + incident
  /// (Le client rapporte une unité défectueuse → elle revient physiquement
  /// mais n'est pas disponible → directement en blocked.)
  static Future<void> returnDefective({
    required String shopId,
    required String productId,
    required String variantId,
    required int quantity,
    required String productName,
    String? orderId,
  }) async {
    final result = _findVariant(shopId, productId, variantId);
    if (result == null) return;
    final (product, vIdx) = result;
    final v = product.variants[vIdx];

    final beforeBlocked = v.stockBlocked;
    final beforePhys    = v.stockPhysical;

    final updated = v.copyWith(
      stockBlocked:  v.stockBlocked + quantity,
      stockPhysical: v.stockPhysical + quantity,
    );

    await _saveVariant(product, vIdx, updated, shopId);

    final now  = DateTime.now();
    final user = LocalStorageService.getCurrentUser();
    final incident = Incident(
      id: 'inc_${now.microsecondsSinceEpoch}',
      shopId: shopId, productId: productId, variantId: variantId,
      productName: productName, type: IncidentType.inRepair,
      quantity: quantity, notes: 'Retour client défectueux',
      createdBy: user?.name, createdAt: now,
    );
    HiveBoxes.incidentsBox.put(incident.id, incident.toMap());

    _log(shopId: shopId, productId: productId, variantId: variantId,
      type: 'return_defective', quantity: quantity, status: 'defective',
      beforeBlocked: beforeBlocked, afterBlocked: updated.stockBlocked,
      beforePhys: beforePhys, afterPhys: updated.stockPhysical,
      cause: 'client_return', referenceId: orderId);
  }

  // ════════════════════════════════════════════════════════════════════════════
  // 6. AJUSTEMENT MANUEL
  // ════════════════════════════════════════════════════════════════════════════

  static Future<bool> adjustment({
    required String shopId,
    required String productId,
    required String variantId,
    required int delta, // positif = entrée, négatif = sortie
    String? notes,
  }) async {
    final result = _findVariant(shopId, productId, variantId);
    if (result == null) return false;
    final (product, vIdx) = result;
    final v = product.variants[vIdx];

    final newAvail = v.stockAvailable + delta;
    if (newAvail < 0) return false; // bloquer si négatif

    final newPhys = (v.stockPhysical + delta).clamp(0, 999999);
    final updated = v.copyWith(
      stockAvailable: newAvail,
      stockPhysical:  newPhys,
    );

    await _saveVariant(product, vIdx, updated, shopId);
    _log(shopId: shopId, productId: productId, variantId: variantId,
      type: 'adjustment', quantity: delta,
      beforeAvail: v.stockAvailable, afterAvail: updated.stockAvailable,
      beforePhys: v.stockPhysical, afterPhys: updated.stockPhysical,
      notes: notes);
    return true;
  }

  // ════════════════════════════════════════════════════════════════════════════
  // 7. MODIFICATION ARRIVÉE — annuler ancien + appliquer nouveau
  // ════════════════════════════════════════════════════════════════════════════

  static Future<bool> editArrival({
    required String shopId,
    required String productId,
    required String variantId,
    required int oldQty,
    required String oldStatus, // available, damaged, defective, to_inspect
    required int newQty,
    required String newStatus,
  }) async {
    final result = _findVariant(shopId, productId, variantId);
    if (result == null) return false;
    final (product, vIdx) = result;
    final v = product.variants[vIdx];

    // Calculer les deltas
    int deltaAvail = 0, deltaBlocked = 0, deltaPhys = 0;

    // Annuler l'ancien
    if (oldStatus == 'available') {
      deltaAvail -= oldQty;
      deltaPhys  -= oldQty;
    } else {
      deltaBlocked -= oldQty;
      deltaPhys    -= oldQty;
    }

    // Appliquer le nouveau
    if (newStatus == 'available') {
      deltaAvail += newQty;
      deltaPhys  += newQty;
    } else {
      deltaBlocked += newQty;
      deltaPhys    += newQty;
    }

    // Vérifier que ça ne rend pas stock_available négatif
    if (v.stockAvailable + deltaAvail < 0) return false;

    final updated = v.copyWith(
      stockAvailable: (v.stockAvailable + deltaAvail).clamp(0, 999999),
      stockBlocked:   (v.stockBlocked + deltaBlocked).clamp(0, 999999),
      stockPhysical:  (v.stockPhysical + deltaPhys).clamp(0, 999999),
    );

    await _saveVariant(product, vIdx, updated, shopId);
    _log(shopId: shopId, productId: productId, variantId: variantId,
      type: 'arrival_edit', quantity: newQty - oldQty,
      beforeAvail: v.stockAvailable, afterAvail: updated.stockAvailable,
      beforeBlocked: v.stockBlocked, afterBlocked: updated.stockBlocked,
      beforePhys: v.stockPhysical, afterPhys: updated.stockPhysical,
      notes: '$oldStatus:$oldQty → $newStatus:$newQty');
    return true;
  }

  // ════════════════════════════════════════════════════════════════════════════
  // 8. SUPPRESSION ARRIVÉE — vérifier avant d'autoriser
  // ════════════════════════════════════════════════════════════════════════════

  /// Retourne null si OK, ou un message d'erreur si bloqué.
  static String? canDeleteArrival({
    required String shopId,
    required String productId,
    required String variantId,
    required int quantity,
    required String status,
  }) {
    if (status != 'available') return null; // blocked → toujours supprimable
    final result = _findVariant(shopId, productId, variantId);
    if (result == null) return 'Variante introuvable';
    final (_, vIdx) = result;
    final v = result!.$1.variants[vIdx];
    if (v.stockAvailable < quantity) {
      return 'Stock insuffisant (${v.stockAvailable} disponible, '
          '$quantity à supprimer) — des unités ont déjà été vendues';
    }
    return null;
  }

  static Future<void> deleteArrival({
    required String shopId,
    required String productId,
    required String variantId,
    required int quantity,
    required String status,
  }) async {
    // Log avant recalcul
    final result = _findVariant(shopId, productId, variantId);
    final beforeAvail   = result != null ? result.$1.variants[result.$2].stockAvailable : 0;
    final beforeBlocked = result != null ? result.$1.variants[result.$2].stockBlocked : 0;
    final beforePhys    = result != null ? result.$1.variants[result.$2].stockPhysical : 0;

    // Recalculer depuis les arrivées restantes (après suppression de l'arrivée dans Hive par l'appelant)
    await recalculate(shopId: shopId, productId: productId, variantId: variantId);

    // Log supplémentaire
    _log(shopId: shopId, productId: productId, variantId: variantId,
      type: 'arrival_delete', quantity: -quantity,
      beforeAvail: beforeAvail, afterAvail: null,
      beforeBlocked: beforeBlocked, afterBlocked: null,
      beforePhys: beforePhys, afterPhys: null,
      notes: 'Suppression arrivée $status ×$quantity');
  }

  // ════════════════════════════════════════════════════════════════════════════
  // 9. RECALCUL COMPLET — reconstruit les 4 champs depuis les arrivées réelles
  // ════════════════════════════════════════════════════════════════════════════

  /// Recalcule stock_available, stock_blocked, stock_physical depuis les
  /// événements (arrivées, ventes, incidents) dans Hive.
  ///
  /// Nouveau modèle :
  ///   - Arrivées contribuent à `available` et `physical`
  ///   - Ventes décrémentent `available` et `physical`
  ///   - Incidents pending/in_progress transfèrent `available` → `blocked`
  ///   - Incidents résolus scrapped/return_supplier décrémentent `physical`
  ///   - Incidents résolus repair_success/discounted : effet net nul
  ///
  /// Pour rétro-compat : les arrivées legacy avec status != 'available'
  /// sont traitées comme arrivée + incident pending.
  static Future<void> recalculate({
    required String shopId,
    required String productId,
    required String variantId,
  }) async {
    final result = _findVariant(shopId, productId, variantId);
    if (result == null) return;
    final (product, vIdx) = result;
    final v = product.variants[vIdx];

    final resolvedVid = v.id ?? variantId;

    bool matchesVariant(Map m, {String vidKey = 'variant_id', String pidKey = 'product_id'}) {
      final aVid = m[vidKey] as String?;
      final aPid = m[pidKey] as String?;
      if (aVid != null && aVid.isNotEmpty) return aVid == resolvedVid;
      return aPid == productId;
    }

    // Arrivées (toutes contribuent au physical ; legacy blocked compté aussi en blocked)
    int totalArrivals = 0;
    int legacyBlocked = 0;
    bool hasArrivals = false;
    for (final raw in HiveBoxes.stockArrivalsBox.values) {
      try {
        final m = Map<String, dynamic>.from(raw as Map);
        if (m['shop_id'] != shopId) continue;
        if (!matchesVariant(m)) continue;
        hasArrivals = true;
        final qty = m['quantity'] as int? ?? 0;
        final status = m['status'] as String? ?? 'available';
        totalArrivals += qty;
        if (status != 'available') legacyBlocked += qty;
      } catch (_) {}
    }

    if (!hasArrivals) return; // pas d'arrivées → garder le stock tel quel

    // Ventes (quantité stockée en négatif dans stock_movements)
    int totalSales = 0;
    for (final raw in HiveBoxes.stockMovementsBox.values) {
      try {
        final m = Map<String, dynamic>.from(raw as Map);
        if (m['shop_id'] != shopId) continue;
        if ((m['type'] as String? ?? '') != 'sale') continue;
        if (!matchesVariant(m)) continue;
        final qty = m['quantity'] as int? ?? 0;
        totalSales += qty.abs();
      } catch (_) {}
    }

    // Incidents : pending/in_progress → blocked ; scrapped/return résolus → sortie physique
    int pendingBlocked = 0;
    int resolvedRemoved = 0;
    for (final raw in HiveBoxes.incidentsBox.values) {
      try {
        final m = Map<String, dynamic>.from(raw as Map);
        if (m['shop_id'] != shopId) continue;
        if (!matchesVariant(m)) continue;
        final qty = m['quantity'] as int? ?? 0;
        final iStatus = m['status'] as String? ?? 'pending';
        final iType   = m['type']   as String? ?? '';
        if (iStatus == 'pending' || iStatus == 'in_progress') {
          pendingBlocked += qty;
        } else if (iStatus == 'resolved' &&
            (iType == 'scrapped' || iType == 'return_supplier')) {
          resolvedRemoved += qty;
        }
      } catch (_) {}
    }

    int totalPhysical = totalArrivals - totalSales - resolvedRemoved;
    int totalBlocked  = pendingBlocked + legacyBlocked;
    int totalAvailable = totalPhysical - totalBlocked;

    totalAvailable = totalAvailable.clamp(0, 999999);
    totalBlocked   = totalBlocked.clamp(0, 999999);
    totalPhysical  = totalPhysical.clamp(0, 999999);

    final updated = v.copyWith(
      stockAvailable: totalAvailable,
      stockBlocked:   totalBlocked,
      stockPhysical:  totalPhysical,
    );

    await _saveVariant(product, vIdx, updated, shopId);
    _log(shopId: shopId, productId: productId, variantId: variantId,
      type: 'recalculate', quantity: 0,
      beforeAvail: v.stockAvailable, afterAvail: updated.stockAvailable,
      beforeBlocked: v.stockBlocked, afterBlocked: updated.stockBlocked,
      beforePhys: v.stockPhysical, afterPhys: updated.stockPhysical,
      notes: 'Recalcul complet depuis arrivées + ventes');
  }

  // ════════════════════════════════════════════════════════════════════════════
  // HELPERS PRIVÉS
  // ════════════════════════════════════════════════════════════════════════════

  /// Trouve un produit + index de la variante. Cherche par variantId d'abord,
  /// puis par productId (produit sans variante).
  static (Product, int)? _findVariant(String shopId, String productId, String variantId) {
    final products = AppDatabase.getProductsForShop(shopId);
    for (final p in products) {
      for (int i = 0; i < p.variants.length; i++) {
        if (p.variants[i].id == variantId) return (p, i);
      }
      if (p.id == productId && p.variants.isNotEmpty) return (p, 0);
    }
    return null;
  }

  /// Sauvegarde la variante mise à jour + propage le stock global + notifie.
  static Future<void> _saveVariant(
      Product product, int vIdx, ProductVariant updated, String shopId) async {
    final variants = List<ProductVariant>.from(product.variants);
    variants[vIdx] = updated;
    await AppDatabase.saveProduct(product.copyWith(variants: variants),
        skipValidation: true); // pas de revalidation SKU pour les mises à jour stock
    AppDatabase.notifyProductChange(shopId);
  }

  /// Log inaltérable dans stock_movements.
  static void _log({
    required String shopId,
    required String productId,
    required String variantId,
    required String type,
    required int quantity,
    int? beforeAvail, int? afterAvail,
    int? beforeBlocked, int? afterBlocked,
    int? beforePhys, int? afterPhys,
    String? status, String? cause,
    String? notes, String? referenceId,
  }) {
    final now  = DateTime.now();
    final user = LocalStorageService.getCurrentUser();
    final map = <String, dynamic>{
      'id': 'sm_${now.microsecondsSinceEpoch}_$type',
      'shop_id': shopId,
      'product_id': productId,
      'variant_id': variantId,
      'type': type,
      'quantity': quantity,
      'before_available': beforeAvail,
      'after_available': afterAvail,
      'before_blocked': beforeBlocked,
      'after_blocked': afterBlocked,
      'before_physical': beforePhys,
      'after_physical': afterPhys,
      'status': status,
      'cause': cause,
      'notes': notes,
      'reference_id': referenceId,
      'created_by': user?.name,
      'created_at': now.toIso8601String(),
    };
    HiveBoxes.stockMovementsBox.put(map['id'], map);
  }

  // ════════════════════════════════════════════════════════════════════════════
  // TRANSFERTS ENTRE EMPLACEMENTS (Phase 4 — Option 1 instantanée)
  // ════════════════════════════════════════════════════════════════════════════

  /// Raison d'un éventuel refus d'un transfert. `null` si tout est OK.
  static String? validateTransferLines({
    required StockLocation fromLoc,
    StockLocation? toLoc,
    required List<StockTransferLine> lines,
  }) {
    if (lines.isEmpty) return 'Ajoutez au moins une ligne au transfert';
    for (final line in lines) {
      if (line.quantity <= 0) return 'Toutes les quantités doivent être > 0';
      final available = _availableAtLocation(fromLoc, line.variantId);
      if (available < line.quantity) {
        final name = line.productName ?? line.variantName ?? line.variantId;
        return 'Stock insuffisant pour "$name" '
            '(disponible : $available, demandé : ${line.quantity})';
      }
    }
    // Transfert shop → shop différent : chaque variante source doit avoir
    // un SKU (identité métier transversale aux boutiques, voir auto-merge
    // dans _applyTransferLine / _resolveOrCreateVariantInShop).
    if (toLoc != null
        && toLoc.type == StockLocationType.shop
        && toLoc.shopId != null
        && toLoc.shopId != fromLoc.shopId) {
      for (final line in lines) {
        final found = _findVariantGlobally(line.variantId);
        if (found == null) continue;
        final sku = found.$2.sku?.trim() ?? '';
        if (sku.isEmpty) {
          final name = line.productName ?? line.variantName ?? line.variantId;
          return 'Variante "$name" sans SKU. Le transfert entre boutiques '
              'nécessite un SKU sur chaque variante (identité partagée).';
        }
      }
    }
    return null;
  }

  /// Exécute un transfert instantané : décrémente source, incrémente
  /// destination. Si la source ou la destination est une boutique (type=shop),
  /// met aussi à jour la variante pour rester cohérent avec le fallback
  /// Phase 1. Crée 2 entrées stock_movements (sortie + entrée) corrélées
  /// par le même `reference` = transferId.
  ///
  /// Retourne le StockTransfer créé (status=received) ou null si rejeté.
  static Future<StockTransfer?> executeTransfer({
    required String ownerId,
    required String fromLocationId,
    required String toLocationId,
    required List<StockTransferLine> lines,
    String? notes,
  }) async {
    if (fromLocationId == toLocationId) return null;
    if (lines.isEmpty) return null;

    final locations = AppDatabase.getStockLocationsForOwner(ownerId);
    final fromLoc = locations.where((l) => l.id == fromLocationId).firstOrNull;
    final toLoc   = locations.where((l) => l.id == toLocationId).firstOrNull;
    if (fromLoc == null || toLoc == null) return null;

    // Re-validation défensive (stocks peuvent avoir changé depuis saisie,
    // ou SKU manquant pour un transfert shop → shop différent).
    final err = validateTransferLines(
        fromLoc: fromLoc, toLoc: toLoc, lines: lines);
    if (err != null) {
      debugPrint('[StockService] transfer rejected: $err');
      throw Exception(err);
    }

    final now = DateTime.now();
    final transferId = 'trf_${now.microsecondsSinceEpoch}';

    for (final line in lines) {
      await _applyTransferLine(
        transferId: transferId,
        fromLoc:    fromLoc,
        toLoc:      toLoc,
        line:       line,
        now:        now,
        notes:      notes,
      );
    }

    final user = LocalStorageService.getCurrentUser();
    final transfer = StockTransfer(
      id:             transferId,
      ownerId:        ownerId,
      fromLocationId: fromLocationId,
      toLocationId:   toLocationId,
      status:         StockTransferStatus.received, // instantané
      lines:          lines,
      notes:          notes,
      createdBy:      user?.name,
      createdAt:      now,
      shippedAt:      now,
      receivedAt:     now,
    );
    await AppDatabase.saveStockTransfer(transfer);

    // Audit "métier" — bidirectionnel : on émet un log dans la boutique
    // SOURCE (action stock_transfer_out) ET dans la boutique DESTINATION
    // (action stock_transfer_in), si les deux sont des shops distincts.
    // Cela garantit que l'historique des deux côtés voit le mouvement.
    // Si un côté n'est pas un shop (warehouse/partner), seul le côté shop
    // reçoit le log avec sa direction propre.
    final totalQty = lines.fold<int>(0, (s, l) => s + l.quantity);
    final commonDetails = <String, dynamic>{
      'from':      fromLoc.name,
      'to':        toLoc.name,
      'quantity':  totalQty,
      'lines':     lines.length,
      'reference': transferId,
      if ((notes ?? '').isNotEmpty) 'notes': notes,
    };
    final fromShopId = fromLoc.shopId;
    final toShopId   = toLoc.shopId;
    if (fromShopId != null) {
      await ActivityLogService.log(
        action:      'stock_transfer_out',
        targetType:  'stock',
        targetId:    transferId,
        targetLabel: '${fromLoc.name} → ${toLoc.name}',
        shopId:      fromShopId,
        details:     {...commonDetails, 'direction': 'out'},
      );
    }
    if (toShopId != null && toShopId != fromShopId) {
      await ActivityLogService.log(
        action:      'stock_transfer_in',
        targetType:  'stock',
        targetId:    transferId,
        targetLabel: '${fromLoc.name} → ${toLoc.name}',
        shopId:      toShopId,
        details:     {...commonDetails, 'direction': 'in'},
      );
    }
    return transfer;
  }

  /// Applique une ligne : décrément source + incrément destination.
  ///
  /// Si la destination est un shop différent de la source, le `variantId`
  /// source (local à la boutique d'origine) est résolu en `variantId`
  /// destination via le SKU (auto-merge — voir [_resolveOrCreateVariantInShop]).
  /// Cela permet de garder le SKU comme identité métier transversale, tout
  /// en respectant le fait que chaque boutique a ses propres `Product`/
  /// `ProductVariant`.
  static Future<void> _applyTransferLine({
    required String transferId,
    required StockLocation fromLoc,
    required StockLocation toLoc,
    required StockTransferLine line,
    required DateTime now,
    String? notes,
  }) async {
    final srcVid = line.variantId;
    final qty = line.quantity;

    // Résolution du variantId côté destination si besoin (auto-merge SKU).
    String dstVid = srcVid;
    String? dstProductId;
    final crossShop = toLoc.type == StockLocationType.shop
        && toLoc.shopId != null
        && toLoc.shopId != fromLoc.shopId;
    if (crossShop) {
      final inDest = AppDatabase.getProductsForShop(toLoc.shopId!)
          .any((p) => p.variants.any((v) => v.id == srcVid));
      if (!inDest) {
        final mapped =
            await _resolveOrCreateVariantInShop(srcVid, toLoc.shopId!);
        dstProductId = mapped.$1;
        dstVid       = mapped.$2;
      }
    }

    // 1. Débit source (variantId source)
    final beforeSrc = _availableAtLocation(fromLoc, srcVid);
    await _debitLocation(fromLoc, srcVid, qty, now);
    final afterSrc = beforeSrc - qty;

    // 2. Crédit destination (variantId destination, possiblement remappé)
    final beforeDst = _availableAtLocation(toLoc, dstVid);
    await _creditLocation(toLoc, dstVid, qty, now);
    final afterDst = beforeDst + qty;

    // 3. Logs (2x) — un par "shop de rattachement" pour rester compatible
    //    avec l'actuelle table stock_movements qui exige un shop_id.
    final srcShopId = _shopIdFor(fromLoc);
    final dstShopId = _shopIdFor(toLoc);
    final srcProductId = _resolveProductId(fromLoc, srcVid) ?? '';
    final dstProductIdFinal = dstProductId
        ?? _resolveProductId(toLoc, dstVid)
        ?? srcProductId;

    // Sortie
    _log(
      shopId:     srcShopId,
      productId:  srcProductId,
      variantId:  srcVid,
      type:       'transfer',
      quantity:   -qty,
      beforeAvail: beforeSrc,
      afterAvail:  afterSrc,
      notes:      'Transfert vers "${toLoc.name}"${(notes ?? '').isNotEmpty ? ' — $notes' : ''}',
      referenceId: transferId,
    );
    // Entrée
    _log(
      shopId:     dstShopId,
      productId:  dstProductIdFinal,
      variantId:  dstVid,
      type:       'transfer',
      quantity:   qty,
      beforeAvail: beforeDst,
      afterAvail:  afterDst,
      notes:      'Transfert depuis "${fromLoc.name}"${(notes ?? '').isNotEmpty ? ' — $notes' : ''}',
      referenceId: transferId,
    );
  }

  /// Retourne le stock disponible d'une variante à un emplacement.
  /// Pour une shop : lit la variante (source de vérité Phase 1).
  /// Pour warehouse/partner : lit le StockLevel.
  static int _availableAtLocation(StockLocation loc, String variantId) {
    if (loc.type == StockLocationType.shop && loc.shopId != null) {
      for (final p in AppDatabase.getProductsForShop(loc.shopId!)) {
        for (final v in p.variants) {
          if (v.id == variantId) return v.stockAvailable;
        }
      }
      return 0;
    }
    final lvl = AppDatabase.getStockLevel(variantId, loc.id);
    return lvl?.stockAvailable ?? 0;
  }

  /// Décrémente le stock disponible à un emplacement.
  static Future<void> _debitLocation(
      StockLocation loc, String variantId, int qty, DateTime now) async {
    // StockLevel (toujours mis à jour, même pour shop)
    final lvl = AppDatabase.getStockLevel(variantId, loc.id);
    if (lvl != null) {
      final updated = lvl.copyWith(
        stockAvailable: (lvl.stockAvailable - qty).clamp(0, 1 << 31),
        stockPhysical:  (lvl.stockPhysical  - qty).clamp(0, 1 << 31),
        updatedAt:      now,
      );
      await AppDatabase.saveStockLevel(updated);
    }
    // Fallback Phase 1 : si shop, mettre à jour la variante aussi
    if (loc.type == StockLocationType.shop && loc.shopId != null) {
      await _adjustVariantStock(loc.shopId!, variantId, -qty);
    }
  }

  /// Incrémente le stock disponible à un emplacement.
  /// Crée un StockLevel s'il n'existe pas encore.
  static Future<void> _creditLocation(
      StockLocation loc, String variantId, int qty, DateTime now) async {
    final existing = AppDatabase.getStockLevel(variantId, loc.id);
    final shopId = loc.type == StockLocationType.shop ? loc.shopId : null;
    if (existing != null) {
      final updated = existing.copyWith(
        stockAvailable: existing.stockAvailable + qty,
        stockPhysical:  existing.stockPhysical  + qty,
        updatedAt:      now,
      );
      await AppDatabase.saveStockLevel(updated);
    } else {
      final created = StockLevel(
        id:             'lvl_${variantId}_${loc.id}',
        variantId:      variantId,
        locationId:     loc.id,
        shopId:         shopId,
        stockAvailable: qty,
        stockPhysical:  qty,
        stockBlocked:   0,
        stockOrdered:   0,
        updatedAt:      now,
      );
      await AppDatabase.saveStockLevel(created);
    }
    if (loc.type == StockLocationType.shop && loc.shopId != null) {
      await _adjustVariantStock(loc.shopId!, variantId, qty);
    }
  }

  /// Modifie le stockAvailable/stockPhysical de la variante d'un produit
  /// dans une boutique (fallback Phase 1). delta peut être négatif.
  static Future<void> _adjustVariantStock(
      String shopId, String variantId, int delta) async {
    final products = AppDatabase.getProductsForShop(shopId);
    for (final p in products) {
      for (int i = 0; i < p.variants.length; i++) {
        if (p.variants[i].id != variantId) continue;
        final v = p.variants[i];
        final updated = v.copyWith(
          stockAvailable: (v.stockAvailable + delta).clamp(0, 1 << 31),
          stockPhysical:  (v.stockPhysical  + delta).clamp(0, 1 << 31),
        );
        await _saveVariant(p, i, updated, shopId);
        return;
      }
    }
  }

  static String _shopIdFor(StockLocation loc) =>
      loc.shopId ?? ''; // warehouse/partner : pas de shop → shop_id vide
  // NB : si ton schéma stock_movements impose shop_id NOT NULL, les logs
  // associés à warehouse/partner échoueront Supabase. On les garde en local
  // pour traçabilité ; on ajustera si besoin (le log sortie est toujours
  // rattaché à un shop_id valide si fromLoc est une shop).

  /// Essaie de retrouver le productId d'une variante via la location :
  /// si shop → scan des produits de cette boutique. Sinon → scan large.
  static String? _resolveProductId(StockLocation loc, String variantId) {
    if (loc.type == StockLocationType.shop && loc.shopId != null) {
      for (final p in AppDatabase.getProductsForShop(loc.shopId!)) {
        for (final v in p.variants) {
          if (v.id == variantId) return p.id;
        }
      }
    }
    // Scan large (toutes les boutiques du owner)
    final userId = LocalStorageService.getCurrentUser()?.id ?? '';
    for (final s in LocalStorageService.getShopsForUser(userId)) {
      for (final p in AppDatabase.getProductsForShop(s.id)) {
        for (final v in p.variants) {
          if (v.id == variantId) return p.id;
        }
      }
    }
    return null;
  }

  /// Cherche globalement (toutes les boutiques du owner) la variante par son
  /// id technique. Retourne (Product, ProductVariant) ou null si introuvable.
  static (Product, ProductVariant)? _findVariantGlobally(String variantId) {
    final userId = LocalStorageService.getCurrentUser()?.id ?? '';
    for (final s in LocalStorageService.getShopsForUser(userId)) {
      for (final p in AppDatabase.getProductsForShop(s.id)) {
        for (final v in p.variants) {
          if (v.id == variantId) return (p, v);
        }
      }
    }
    return null;
  }

  /// Résout (ou crée) la variante équivalente d'une variante source dans la
  /// boutique destination, en s'appuyant sur le **SKU** comme identité métier
  /// transversale aux boutiques.
  ///
  /// Comportement :
  /// 1. Si une variante avec le même SKU existe en B → retourne son
  ///    `(productId, variantId)`.
  /// 2. Sinon, si un Product en B a le même `Product.sku` que la source →
  ///    ajoute la variante (clone, **SKU préservé**) à ce produit existant.
  /// 3. Sinon, crée un nouveau Product en B (nouveau productId, **SKU
  ///    préservés** sur Product et Variant). `categoryId`/`brand` sont
  ///    laissés `null` côté B (les IDs de catégories/marques sont locaux à
  ///    chaque boutique — l'utilisateur les rattache après s'il le souhaite).
  ///
  /// Lance une [Exception] si :
  /// - La variante source est introuvable.
  /// - La variante source n'a pas de SKU non vide.
  static Future<(String productId, String variantId)>
      _resolveOrCreateVariantInShop(
          String sourceVariantId, String destShopId) async {
    final found = _findVariantGlobally(sourceVariantId);
    if (found == null) {
      throw Exception('Variante source introuvable (id=$sourceVariantId)');
    }
    final (srcProduct, srcVariant) = found;
    final sku = srcVariant.sku?.trim() ?? '';
    if (sku.isEmpty) {
      throw Exception(
          'Variante "${srcVariant.name}" sans SKU. '
          'Le transfert entre boutiques nécessite un SKU sur chaque '
          'variante (identité partagée).');
    }

    // 1. Match exact par SKU sur les variantes des produits de B.
    final destProducts = AppDatabase.getProductsForShop(destShopId);
    Product? matchedProduct;
    ProductVariant? matchedVariant;
    int matchCount = 0;
    for (final p in destProducts) {
      for (final v in p.variants) {
        if ((v.sku ?? '') == sku) {
          matchedProduct ??= p;
          matchedVariant ??= v;
          matchCount++;
        }
      }
    }
    if (matchCount > 1) {
      debugPrint(
          '[StockService] ⚠️ SKU "$sku" en doublon dans la boutique '
          '$destShopId ($matchCount occurrences). On utilise la première.');
    }
    if (matchedProduct?.id != null && matchedVariant?.id != null) {
      return (matchedProduct!.id!, matchedVariant!.id!);
    }

    // 2. Sinon : faut-il greffer la nouvelle variante sur un Product
    //    existant (Product.sku correspond) ou créer un nouveau Product ?
    final productSku = srcProduct.sku?.trim() ?? '';
    final hostProduct = productSku.isEmpty
        ? null
        : destProducts
            .where((p) => (p.sku ?? '').trim() == productSku)
            .firstOrNull;

    final ts = DateTime.now().microsecondsSinceEpoch;
    final newVariant = ProductVariant(
      id:                 'var_${ts}_merge',
      name:               srcVariant.name,
      sku:                srcVariant.sku,        // PRÉSERVÉ
      barcode:            srcVariant.barcode,
      supplier:           srcVariant.supplier,
      supplierRef:        srcVariant.supplierRef,
      priceBuy:           srcVariant.priceBuy,
      priceSellPos:       srcVariant.priceSellPos,
      priceSellWeb:       srcVariant.priceSellWeb,
      stockAvailable:     0, // sera incrémenté par _adjustVariantStock
      stockPhysical:      0,
      stockOrdered:       0,
      stockBlocked:       0,
      stockMinAlert:      srcVariant.stockMinAlert,
      imageUrl:           srcVariant.imageUrl,
      secondaryImageUrls: List.from(srcVariant.secondaryImageUrls),
      isMain:             srcVariant.isMain,
      promoEnabled:       false,
    );

    if (hostProduct != null) {
      // 2a. Greffer sur le Product hôte existant.
      final updated = hostProduct.copyWith(
        variants: [...hostProduct.variants, newVariant],
      );
      await AppDatabase.saveProduct(updated, skipValidation: true);
      debugPrint(
          '[StockService] ✅ Auto-merge: variante "${srcVariant.name}" '
          '(SKU=$sku) ajoutée au produit existant en boutique $destShopId');
      await ActivityLogService.log(
        action:      'product_auto_merged',
        targetType:  'product',
        targetId:    hostProduct.id,
        targetLabel: '${hostProduct.name} — ${srcVariant.name}',
        shopId:      destShopId,
        details: {
          'sku':       sku,
          'mode':      'variant_added',
          'host_product': hostProduct.name,
        },
      );
      return (hostProduct.id!, newVariant.id!);
    }

    // 2b. Créer un nouveau Product en B.
    final newProductId = 'prod_${ts}_merge';
    final newProduct = Product(
      id:            newProductId,
      storeId:       destShopId,
      categoryId:    null, // décision : non copié (IDs locaux à chaque shop)
      brand:         null, // idem
      name:          srcProduct.name,
      description:   srcProduct.description,
      barcode:       srcProduct.barcode,
      sku:           srcProduct.sku,             // PRÉSERVÉ
      priceBuy:      srcProduct.priceBuy,
      customsFee:    srcProduct.customsFee,
      priceSellPos:  srcProduct.priceSellPos,
      priceSellWeb:  srcProduct.priceSellWeb,
      taxRate:       srcProduct.taxRate,
      stockQty:      0,
      stockMinAlert: srcProduct.stockMinAlert,
      isActive:      srcProduct.isActive,
      isVisibleWeb:  false,
      imageUrl:      srcProduct.imageUrl,
      rating:        srcProduct.rating,
      variants:      [newVariant],
      expenses:      const [],
    );
    await AppDatabase.saveProduct(newProduct, skipValidation: true);
    debugPrint(
        '[StockService] ✅ Auto-merge: produit "${srcProduct.name}" '
        '(SKU=${srcProduct.sku}) créé en boutique $destShopId avec '
        'variante "${srcVariant.name}" (SKU=$sku)');
    await ActivityLogService.log(
      action:      'product_auto_merged',
      targetType:  'product',
      targetId:    newProductId,
      targetLabel: '${srcProduct.name} — ${srcVariant.name}',
      shopId:      destShopId,
      details: {
        'sku':              sku,
        'mode':             'product_created',
        'product_sku':      srcProduct.sku,
      },
    );
    return (newProductId, newVariant.id!);
  }
}
