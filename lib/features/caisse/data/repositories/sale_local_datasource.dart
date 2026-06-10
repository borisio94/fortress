import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../../../core/storage/hive_boxes.dart';
import '../../../../core/services/stock_service.dart';
import '../../../../core/services/delivery_reminder_service.dart';
import '../../../../core/database/app_database.dart';
import '../../domain/entities/sale.dart';
import '../../domain/entities/sale_item.dart';
import '../../domain/approval_closure.dart';

/// Datasource local Hive pour les ventes offline et le panier persistant.
/// Nommé SaleLocalDatasource (pas de conflit avec l'entité Sale).
class SaleLocalDatasource {
  Box   get _box       => HiveBoxes.settingsBox;
  Box<Map> get _ordersBox => HiveBoxes.ordersBox;

  Future<void> saveSaleOffline(Sale sale) async {
    final key = 'pending_sale_${DateTime.now().millisecondsSinceEpoch}';
    await _box.put(key, jsonEncode(_saleToMap(sale)));
  }

  Future<List<Sale>> getPendingSales(String shopId) async {
    final keys = _box.keys
        .where((k) => (k as String).startsWith('pending_sale_'))
        .toList();
    return keys
        .map((k) {
      final raw =
      jsonDecode(_box.get(k) as String) as Map<String, dynamic>;
      return _mapToSale(raw);
    })
        .where((s) => s.shopId == shopId)
        .toList();
  }

  Future<void> removePendingSale(String key) => _box.delete(key);

  Future<void> saveCart(List<SaleItem> items) async {
    await HiveBoxes.cartBox
        .put('cart', jsonEncode(items.map(_itemToMap).toList()));
  }

  Future<List<SaleItem>> loadCart() async {
    final raw = HiveBoxes.cartBox.get('cart');
    if (raw == null) return [];
    final list = jsonDecode(raw as String) as List;
    return list
        .map((e) => SaleItem(
      productId: e['product_id'] as String,
      productName: e['name'] as String,
      unitPrice: (e['price'] as num).toDouble(),
      quantity: e['qty'] as int,
    ))
        .toList();
  }

  Future<void> clearCart() => HiveBoxes.cartBox.delete('cart');

  Future<void> enqueueOfflineAction(Map<String, dynamic> action) async {
    await HiveBoxes.offlineQueueBox.add(action);
  }

  // ── Commandes (e-commerce) ────────────────────────────────────────────────

  /// Sauvegarder une commande avec son statut
  Future<void> saveOrder(Sale order) async {
    if (!Hive.isBoxOpen(HiveBoxes.orders)) return;
    final id = order.id ?? 'order_${DateTime.now().millisecondsSinceEpoch}';

    // Date de complétion stampée uniquement si la commande est créée "completed"
    final completedAt = order.status == SaleStatus.completed
        ? DateTime.now().toUtc().toIso8601String()
        : null;

    // ── Map Hive (stockage local) ─────────────────────────────────
    final hiveMap = <String, dynamic>{
      'id':             id,
      'shop_id':        order.shopId,
      'status':         order.status.name,
      'discount_amount': order.discountAmount,
      'tax_rate':       order.taxRate,
      'payment_method': order.paymentMethod.name,
      'client_id':      order.clientId,
      'client_name':    order.clientName,
      'client_phone':   order.clientPhone,
      'notes':          order.notes,
      'scheduled_at':   order.scheduledAt?.toUtc().toIso8601String(),
      'delivery_mode':        order.deliveryMode?.key,
      'delivery_location_id': order.deliveryLocationId,
      'delivery_person_name': order.deliveryPersonName,
      'created_by_user_id':   order.createdByUserId,
      'delivery_city':        order.deliveryCity,
      'delivery_address':     order.deliveryAddress,
      'shipment_city':        order.shipmentCity,
      'shipment_agency':      order.shipmentAgency,
      'shipment_handler':     order.shipmentHandler,
      'cancellation_reason':  order.cancellationReason,
      'reschedule_reason':    order.rescheduleReason,
      'amount_paid':          order.amountPaid,
      'payment_status':       order.paymentStatus.key,
      'created_at':     order.createdAt.toUtc().toIso8601String(),
      'completed_at':   completedAt,
      'is_approval_sale': order.isApprovalSale,
      'stock_reserved':   order.stockReserved,
      'fees':           order.fees,
      // GF-1 : clé d'idempotence du panier — persistée en Hive ET pushée
      // à Supabase pour bénéficier de l'UNIQUE constraint (hotfix_080).
      'idempotency_key': order.idempotencyKey,
      'items': order.items.map((i) => {
        'product_id':   i.productId,
        'product_name': i.productName,
        'unit_price':   i.unitPrice,
        'price_buy':    i.priceBuy,
        'custom_price': i.customPrice,
        'quantity':     i.quantity,
        'discount':     i.discount,
        'image_url':    i.imageUrl,
        'variant_name': i.variantName,
      }).toList(),
    };

    // ── Map Supabase (colonnes exactes de la table orders) ────────
    final supaMap = <String, dynamic>{
      'id':             id,
      'shop_id':        order.shopId,
      'status':         order.status.name,
      'discount_amount': order.discountAmount,
      'tax_rate':       order.taxRate,
      'payment_method': order.paymentMethod.name,
      'client_id':      order.clientId,
      'client_name':    order.clientName,
      'client_phone':   order.clientPhone,
      'notes':          order.notes,
      'scheduled_at':   order.scheduledAt?.toUtc().toIso8601String(),
      'delivery_mode':        order.deliveryMode?.key,
      'delivery_location_id': order.deliveryLocationId,
      'delivery_person_name': order.deliveryPersonName,
      'created_by_user_id':   order.createdByUserId,
      'delivery_city':        order.deliveryCity,
      'delivery_address':     order.deliveryAddress,
      'shipment_city':        order.shipmentCity,
      'shipment_agency':      order.shipmentAgency,
      'shipment_handler':     order.shipmentHandler,
      'cancellation_reason':  order.cancellationReason,
      'reschedule_reason':    order.rescheduleReason,
      'amount_paid':          order.amountPaid,
      'payment_status':       order.paymentStatus.key,
      'created_at':     order.createdAt.toUtc().toIso8601String(),
      'completed_at':   completedAt,
      'synced_to_cloud': false,
      'idempotency_key': order.idempotencyKey, // GF-1
      'is_approval_sale': order.isApprovalSale,
      'stock_reserved':   order.stockReserved,
      'fees':           order.fees,
      'items': order.items.map((i) => {
        'product_id':   i.productId,
        'product_name': i.productName,
        'unit_price':   i.unitPrice,
        'price_buy':    i.priceBuy,
        'custom_price': i.customPrice,
        'quantity':     i.quantity,
        'discount':     i.discount,
        'image_url':    i.imageUrl,
        'variant_name': i.variantName,
      }).toList(),
    };

    // 1. Hive IMMÉDIATEMENT — offline-first
    await _ordersBox.put(id, hiveMap);
    // 2. Si vente "completed" avec un client, refresh totalSpent/totalOrders
    if (order.status == SaleStatus.completed && order.clientId != null) {
      await AppDatabase.refreshClientMetrics(order.clientId!, order.shopId);
    }
    // 3. Notifier les listeners pour rafraîchir le dashboard instantanément
    AppDatabase.notifyOrderChange(order.shopId);
    // 4. Supabase en arrière-plan avec la bonne map
    AppDatabase.bgWriteOrder(supaMap);
  }

  /// Récupérer une commande par son id (cross-shop).
  /// Utile pour lire l'état d'une commande avant/après un changement de
  /// statut, sans avoir à connaître son shopId.
  ///
  /// Les commandes soft-deleted (hotfix_084) sont MASQUÉES par défaut.
  /// Passer [includeDeleted] = true pour les inclure (utile à
  /// `DeleteSaleUseCase` qui doit relire l'ordre pour faire un rollback
  /// précis ou à l'écran super-admin de restauration).
  Sale? getOrderById(String orderId, {bool includeDeleted = false}) {
    try {
      if (!Hive.isBoxOpen(HiveBoxes.orders)) return null;
      final raw = _ordersBox.get(orderId);
      if (raw == null) return null;
      final sale = _mapToSaleWithStatus(Map<String, dynamic>.from(raw));
      if (!includeDeleted && sale.isDeleted) return null;
      return sale;
    } catch (_) {
      return null;
    }
  }

  /// Récupérer toutes les commandes d'une boutique.
  /// Filtre les commandes soft-deleted (hotfix_084) — symétrique avec la
  /// RLS Supabase qui les cache aux membres non super-admin.
  List<Sale> getOrders(String shopId) {
    try {
      if (!Hive.isBoxOpen(HiveBoxes.orders)) return [];
      return _ordersBox.values
          .map((m) {
        try {
          return _mapToSaleWithStatus(
              Map<String, dynamic>.from(m));
        } catch (_) { return null; }
      })
          .whereType<Sale>()
          .where((s) => s.shopId == shopId && !s.isDeleted)
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    } catch (_) { return []; }
  }

  /// Mettre à jour le statut d'une commande
  /// Mise à jour complète d'une commande (articles, client, notes, remise, TVA)
  Future<void> updateOrder(Sale order) async {
    if (!Hive.isBoxOpen(HiveBoxes.orders)) return;
    if (order.id == null) return;

    // Conserver completed_at existant, sinon le stamper si status=completed
    final existing = _ordersBox.get(order.id!);
    final previousCompletedAt = existing is Map
        ? existing['completed_at'] as String?
        : null;
    final completedAt = order.status == SaleStatus.completed
        ? (previousCompletedAt ?? DateTime.now().toUtc().toIso8601String())
        : null;

    // Map Hive
    final hiveMap = <String, dynamic>{
      'id':             order.id,
      'shop_id':        order.shopId,
      'status':         order.status.name,
      'discount_amount': order.discountAmount,
      'tax_rate':       order.taxRate,
      'payment_method': order.paymentMethod.name,
      'client_id':      order.clientId,
      'client_name':    order.clientName,
      'client_phone':   order.clientPhone,
      'notes':          order.notes,
      'scheduled_at':   order.scheduledAt?.toUtc().toIso8601String(),
      'delivery_mode':        order.deliveryMode?.key,
      'delivery_location_id': order.deliveryLocationId,
      'delivery_person_name': order.deliveryPersonName,
      'created_by_user_id':   order.createdByUserId,
      'delivery_city':        order.deliveryCity,
      'delivery_address':     order.deliveryAddress,
      'shipment_city':        order.shipmentCity,
      'shipment_agency':      order.shipmentAgency,
      'shipment_handler':     order.shipmentHandler,
      'cancellation_reason':  order.cancellationReason,
      'reschedule_reason':    order.rescheduleReason,
      'amount_paid':          order.amountPaid,
      'payment_status':       order.paymentStatus.key,
      'created_at':     order.createdAt.toUtc().toIso8601String(),
      'completed_at':   completedAt,
      'is_approval_sale': order.isApprovalSale,
      'stock_reserved':   order.stockReserved,
      'fees':           order.fees,
      'items': order.items.map((i) => {
        'product_id':   i.productId,
        'product_name': i.productName,
        'unit_price':   i.unitPrice,
        'price_buy':    i.priceBuy,
        'custom_price': i.customPrice,
        'quantity':     i.quantity,
        'discount':     i.discount,
        'image_url':    i.imageUrl,
        'variant_name': i.variantName,
      }).toList(),
    };
    await _ordersBox.put(order.id!, hiveMap);
    if (order.status == SaleStatus.completed && order.clientId != null) {
      await AppDatabase.refreshClientMetrics(order.clientId!, order.shopId);
    }
    AppDatabase.notifyOrderChange(order.shopId);

    // Sync Supabase
    final supaMap = <String, dynamic>{
      'id':             order.id,
      'shop_id':        order.shopId,
      'status':         order.status.name,
      'discount_amount': order.discountAmount,
      'tax_rate':       order.taxRate,
      'payment_method': order.paymentMethod.name,
      'client_id':      order.clientId,
      'client_name':    order.clientName,
      'client_phone':   order.clientPhone,
      'notes':          order.notes,
      'scheduled_at':   order.scheduledAt?.toUtc().toIso8601String(),
      'delivery_mode':        order.deliveryMode?.key,
      'delivery_location_id': order.deliveryLocationId,
      'delivery_person_name': order.deliveryPersonName,
      'created_by_user_id':   order.createdByUserId,
      'delivery_city':        order.deliveryCity,
      'delivery_address':     order.deliveryAddress,
      'shipment_city':        order.shipmentCity,
      'shipment_agency':      order.shipmentAgency,
      'shipment_handler':     order.shipmentHandler,
      'cancellation_reason':  order.cancellationReason,
      'reschedule_reason':    order.rescheduleReason,
      'amount_paid':          order.amountPaid,
      'payment_status':       order.paymentStatus.key,
      'completed_at':   completedAt,
      'is_approval_sale': order.isApprovalSale,
      'stock_reserved':   order.stockReserved,
      'fees':           order.fees,
      'items': order.items.map((i) => {
        'product_id':   i.productId,
        'product_name': i.productName,
        'unit_price':   i.unitPrice,
        'price_buy':    i.priceBuy,
        'custom_price': i.customPrice,
        'quantity':     i.quantity,
        'discount':     i.discount,
        'image_url':    i.imageUrl,
        'variant_name': i.variantName,
      }).toList(),
    };
    AppDatabase.bgWriteOrder(supaMap);
  }

  /// Met à jour les champs de livraison d'une commande existante (Hive +
  /// Supabase en arrière-plan). Utilisé quand l'utilisateur configure la
  /// livraison au moment de passer la commande à `completed` — couvre le
  /// mode + les détails (ville, adresse, expédition, date programmée).
  Future<void> updateOrderDelivery(
      String orderId, {
      PaymentMethod? paymentMethod,
      DeliveryMode? mode,
      String? locationId,
      String? personName,
      String? deliveryCity,
      String? deliveryAddress,
      String? shipmentCity,
      String? shipmentAgency,
      String? shipmentHandler,
      DateTime? scheduledAt,
  }) async {
    final raw = _ordersBox.get(orderId);
    if (raw == null) return;
    final map = Map<String, dynamic>.from(raw);
    if (paymentMethod != null) {
      map['payment_method'] = paymentMethod.name;
    }
    map['delivery_mode']        = mode?.key;
    map['delivery_location_id'] = locationId;
    map['delivery_person_name'] = personName;
    map['delivery_city']        = deliveryCity;
    map['delivery_address']     = deliveryAddress;
    map['shipment_city']        = shipmentCity;
    map['shipment_agency']      = shipmentAgency;
    map['shipment_handler']     = shipmentHandler;
    if (scheduledAt != null) {
      map['scheduled_at'] = scheduledAt.toUtc().toIso8601String();
    }
    await _ordersBox.put(orderId, map);
    final supaMap = Map<String, dynamic>.from(map);
    supaMap.remove('image_url');
    AppDatabase.bgWriteOrder(supaMap);
  }

  /// Supprime un frais (`orders.fees[feeIndex]`) d'une commande existante.
  /// Persiste Hive + Supabase et notifie le changement pour que la page
  /// Dépenses (frais virtuels dérivés de `orders.fees`) se rafraîchisse
  /// immédiatement. No-op si la commande ou l'index n'existe pas.
  Future<void> deleteOrderFee(String orderId, int feeIndex) async {
    final raw = _ordersBox.get(orderId);
    if (raw == null) return;
    final map = Map<String, dynamic>.from(raw);
    final fees = (map['fees'] as List?)?.toList() ?? [];
    if (feeIndex < 0 || feeIndex >= fees.length) return;
    fees.removeAt(feeIndex);
    map['fees'] = fees;
    await _ordersBox.put(orderId, map);
    final shopId = map['shop_id'] as String?;
    if (shopId != null) AppDatabase.notifyOrderChange(shopId);
    final supaMap = Map<String, dynamic>.from(map);
    supaMap.remove('image_url');
    AppDatabase.bgWriteOrder(supaMap);
  }

  /// Marque une commande comme "annulée par le client" : statut → cancelled
  /// + persiste la raison fournie par l'opérateur.
  /// Effets de bord (notifs, métriques client, sync Supabase) délégués à
  /// updateOrderStatus pour rester cohérent.
  Future<void> cancelOrderWithReason(String orderId, String reason) async {
    final raw = _ordersBox.get(orderId);
    if (raw == null) return;
    final map = Map<String, dynamic>.from(raw);
    map['cancellation_reason'] = reason.trim();
    await _ordersBox.put(orderId, map);
    await updateOrderStatus(orderId, SaleStatus.cancelled);
  }

  /// Enregistre un acompte (ou paiement total) sur une commande en cours.
  /// `newAmountPaid` est la NOUVELLE somme cumulée (pas l'incrément). Calcule
  /// automatiquement `payment_status` selon : 0 → unpaid, < total → partial,
  /// >= total → paid. Ne touche pas au statut de commande (qui reste
  /// scheduled/processing/completed selon le workflow).
  Future<void> recordPayment(String orderId, double newAmountPaid) async {
    final raw = _ordersBox.get(orderId);
    if (raw == null) return;
    final map = Map<String, dynamic>.from(raw);
    final fresh = _mapToSaleWithStatus(map);
    final total = fresh.total;
    final capped = newAmountPaid.clamp(0, total);
    map['amount_paid'] = capped;
    map['payment_status'] = capped <= 0
        ? PaymentStatus.unpaid.key
        : (capped >= total
            ? PaymentStatus.paid.key
            : PaymentStatus.partial.key);
    await _ordersBox.put(orderId, map);
    final shopId = map['shop_id'] as String?;
    if (shopId != null) AppDatabase.notifyOrderChange(shopId);
    final supaMap = Map<String, dynamic>.from(map);
    supaMap.remove('image_url');
    AppDatabase.bgWriteOrder(supaMap);
  }

  /// Reprogramme une commande "en cours" : statut → scheduled, met à jour
  /// la date de livraison, persiste la raison de la reprogrammation. La
  /// présence de `reschedule_reason` sert ensuite de marqueur visuel
  /// "commande reprogrammée" dans la liste.
  Future<void> rescheduleOrder(
      String orderId, DateTime newDate, String reason) async {
    final raw = _ordersBox.get(orderId);
    if (raw == null) return;
    final map = Map<String, dynamic>.from(raw);
    map['scheduled_at']      = newDate.toUtc().toIso8601String();
    map['reschedule_reason'] = reason.trim();
    await _ordersBox.put(orderId, map);
    await updateOrderStatus(orderId, SaleStatus.scheduled);
  }

  /// Bascule le statut d'une commande. Si `completedAt` est fourni ET que
  /// `status == completed`, utilise cette date au lieu de `DateTime.now()`
  /// — permet l'antidatage de l'encaissement (numérisation d'une vente
  /// passée). Sans param, fallback comportement historique (now() au stamp
  /// initial, conservation si déjà stampé).
  Future<void> updateOrderStatus(String orderId, SaleStatus status, {
    DateTime? completedAt,
  }) async {
    final raw = _ordersBox.get(orderId);
    if (raw == null) return;
    final map = Map<String, dynamic>.from(raw);

    // Lire l'ancien statut AVANT modification pour gérer la compensation
    // de stock si on traverse la frontière "completed".
    final oldStatusStr = map['status'] as String? ?? 'scheduled';
    final oldStatus = SaleStatus.values.firstWhere(
        (s) => s.name == oldStatusStr, orElse: () => SaleStatus.scheduled);

    // GF-4 — verrou de transitions. Le contrôle se fait AVANT toute
    // écriture (ni Hive ni Supabase ne reçoivent un état illégal). Les
    // exceptions sont remontées telles quelles aux appelants (CaisseBloc,
    // _processReturn, …) qui montrent un dialog au user.
    if (!SaleStatusTransitions.canTransition(oldStatus, status)) {
      throw TransitionInterditeException(oldStatus, status);
    }
    if (SaleStatusTransitions.requiresMotif(status)) {
      final reason = (map['cancellation_reason'] as String?)?.trim() ?? '';
      if (reason.isEmpty) {
        throw MotifRequiredException(status);
      }
    }

    map['status'] = status.name;
    // Stamp completed_at à la transition → completed. Si l'opérateur a
    // saisi une date custom (antidatage), on l'utilise même si déjà stampé.
    // Sinon : préserver l'existant ou now() par défaut.
    if (status == SaleStatus.completed) {
      if (completedAt != null) {
        map['completed_at'] = completedAt.toUtc().toIso8601String();
      } else {
        map['completed_at'] ??= DateTime.now().toUtc().toIso8601String();
      }
    } else {
      map['completed_at'] = null;
    }
    // Sync paiement avec le statut (cf. hotfix_065). Transition vers
    // completed = encaissement terminé (boutique acompte + partenaire solde
    // ou tout en boutique) → on bascule payment_status à 'paid' et on
    // remplit amount_paid au total facturé pour l'historique. Transition
    // vers refunded → 'refunded'. Transitions inverses (completed → autre)
    // → on remet à unpaid si plus rien d'encaissé est garanti.
    if (status == SaleStatus.completed) {
      // Calculer le total à partir du map (les items contiennent
      // unit_price * quantity ; on respecte les arrondis Sale.total).
      final fresh = _mapToSaleWithStatus(map);
      map['amount_paid']    = fresh.total;
      map['payment_status'] = PaymentStatus.paid.key;
    } else if (status == SaleStatus.refunded) {
      map['payment_status'] = PaymentStatus.refunded.key;
    } else if (oldStatus == SaleStatus.completed) {
      // Quittage du statut completed sans aller à refunded : on n'a plus
      // de garantie d'encaissement total. Repasse à 'unpaid' (l'opérateur
      // peut re-renseigner via le bouton acompte).
      map['amount_paid']    = 0;
      map['payment_status'] = PaymentStatus.unpaid.key;
    }
    await _ordersBox.put(orderId, map);
    final shopId = map['shop_id'] as String?;
    final clientId = map['client_id'] as String?;
    if (shopId != null && clientId != null && clientId.isNotEmpty) {
      await AppDatabase.refreshClientMetrics(clientId, shopId);
    }
    if (shopId != null) AppDatabase.notifyOrderChange(shopId);
    // Envoyer la map COMPLÈTE à Supabase (pas juste id+status)
    // sinon l'upsert écrase la ligne avec des champs null/vides
    final supaMap = Map<String, dynamic>.from(map);
    supaMap.remove('image_url'); // pas de colonne image dans Supabase
    AppDatabase.bgWriteOrder(supaMap);

    // Annuler le rappel de livraison si la commande est finalisée ou
    // annulée ; le reprogrammer si elle redevient programmée/en cours.
    final isInactiveNow = status == SaleStatus.completed
        || status == SaleStatus.cancelled
        || status == SaleStatus.refused
        || status == SaleStatus.refunded;
    if (isInactiveNow) {
      await DeliveryReminderService.cancelFor(orderId);
    } else {
      // Re-programmer avec la date courante de la commande
      await DeliveryReminderService.scheduleFor(_mapToSaleWithStatus(map));
    }

    // ── Compensation de stock selon la transition ──
    // - completed → autre  : la vente n'est plus finalisée → restaurer le stock
    // - autre → completed  : la vente est finalisée → décrémenter le stock
    // - autres transitions : aucun impact stock
    if (oldStatus == status || shopId == null) return;
    final wasCompleted = oldStatus == SaleStatus.completed;
    final nowCompleted = status    == SaleStatus.completed;
    if (wasCompleted == nowCompleted) return;

    final order = _mapToSaleWithStatus(map);
    // Vente « à choisir sur place » : le stock est géré EXPLICITEMENT par
    // reserveApprovalOrder / closeApprovalOrder / cancelApprovalOrder. On ne
    // laisse donc PAS la logique générique décrémenter/restaurer ici, sinon
    // double-comptage (le réservé serait re-décrémenté à la complétion).
    if (order.isApprovalSale) return;
    if (wasCompleted && !nowCompleted) {
      await _restoreOrderStock(order);
    } else {
      await _decrementOrderStock(order);
    }
  }

  /// Restaure le stock d'une commande qui passe de `completed` à un autre
  /// statut. Route vers la bonne source selon le mode de livraison :
  /// partenaire → StockLevel de la location ; sinon → variante boutique.
  static Future<void> _restoreOrderStock(Sale order) async {
    final products = AppDatabase.getProductsForShop(order.shopId);
    final usePartner = order.deliveryMode == DeliveryMode.partner
        && (order.deliveryLocationId ?? '').isNotEmpty;
    for (final item in order.items) {
      final (pid, vid) = _resolveProductVariant(products, item.productId);
      if (pid == null) continue;
      if (usePartner) {
        await StockService.reverseSaleFromLocation(
          locationId: order.deliveryLocationId!,
          variantId:  vid,
          quantity:   item.quantity,
          shopId:     order.shopId,
          productId:  pid,
          orderId:    order.id,
        );
      } else {
        await StockService.reverseSale(
          shopId:    order.shopId,
          productId: pid,
          variantId: vid,
          quantity:  item.quantity,
          orderId:   order.id,
        );
      }
    }
  }

  /// Décrémente le stock d'une commande qui passe à `completed`. Route vers
  /// partenaire ou boutique selon le mode de livraison.
  static Future<void> _decrementOrderStock(Sale order) async {
    final products = AppDatabase.getProductsForShop(order.shopId);
    final usePartner = order.deliveryMode == DeliveryMode.partner
        && (order.deliveryLocationId ?? '').isNotEmpty;
    for (final item in order.items) {
      final (pid, vid) = _resolveProductVariant(products, item.productId);
      if (pid == null) continue;
      if (usePartner) {
        await StockService.saleFromLocation(
          locationId: order.deliveryLocationId!,
          variantId:  vid,
          quantity:   item.quantity,
          shopId:     order.shopId,
          productId:  pid,
          orderId:    order.id,
        );
      } else {
        await StockService.sale(
          shopId:    order.shopId,
          productId: pid,
          variantId: vid,
          quantity:  item.quantity,
          orderId:   order.id,
        );
      }
    }
  }

  // ══════════════════════════════════════════════════════════════════════
  // VENTE « À CHOISIR SUR PLACE » (vente-ou-retour) — Phase 1b
  // Le livreur emporte plusieurs articles candidats ; le client en garde
  // certains, le reste revient. Le stock est géré EXPLICITEMENT ici (jamais
  // par la transition générique, cf. garde-fou `isApprovalSale`) afin de
  // garantir l'invariant anti-perte : total = disponible + réservé(livreur).
  // ══════════════════════════════════════════════════════════════════════

  /// Décrément stock d'UN article pour une commande approval, routé comme
  /// `_decrementOrderStock` : emplacement partenaire (StockLevel) si la
  /// commande est livrée par un partenaire, sinon stock boutique (variante).
  /// C'EST le routage manquant qui faisait échouer la réservation quand on
  /// vend depuis un emplacement partenaire (stock boutique = 0).
  static Future<void> _approvalTakeStock(
      Sale order, String pid, String vid, int qty) async {
    final usePartner = order.deliveryMode == DeliveryMode.partner
        && (order.deliveryLocationId ?? '').isNotEmpty;
    if (usePartner) {
      await StockService.saleFromLocation(
        locationId: order.deliveryLocationId!,
        variantId:  vid,
        quantity:   qty,
        shopId:     order.shopId,
        productId:  pid,
        orderId:    order.id,
      );
    } else {
      await StockService.sale(
        shopId:    order.shopId,
        productId: pid,
        variantId: vid,
        quantity:  qty,
        orderId:   order.id,
      );
    }
  }

  /// Remise en stock d'UN article (retour / annulation / rollback), routée de
  /// la même façon que `_approvalTakeStock`.
  static Future<void> _approvalReturnStock(
      Sale order, String pid, String vid, int qty, String reason) async {
    final usePartner = order.deliveryMode == DeliveryMode.partner
        && (order.deliveryLocationId ?? '').isNotEmpty;
    if (usePartner) {
      await StockService.reverseSaleFromLocation(
        locationId: order.deliveryLocationId!,
        variantId:  vid,
        quantity:   qty,
        shopId:     order.shopId,
        productId:  pid,
        orderId:    order.id,
      );
    } else {
      await StockService.reverseSale(
        shopId:    order.shopId,
        productId: pid,
        variantId: vid,
        quantity:  qty,
        orderId:   order.id,
        reason:    reason,
      );
    }
  }

  /// Réserve (sort du disponible) TOUS les articles candidats d'une commande
  /// « à choisir sur place », puis la persiste en statut `scheduled` avec
  /// `stockReserved = true`. Atomique : si le stock manque sur un article, ce
  /// qui a déjà été décrémenté est restauré avant de relancer l'erreur
  /// (jamais de réservation partielle). Le stock est pris depuis le bon
  /// emplacement (partenaire ou boutique) via `_approvalTakeStock`.
  Future<void> reserveApprovalOrder(Sale order) async {
    if (order.stockReserved) return; // idempotent
    final products = AppDatabase.getProductsForShop(order.shopId);
    final done = <SaleItem>[];
    try {
      for (final item in order.items) {
        final (pid, vid) = _resolveProductVariant(products, item.productId);
        if (pid == null) {
          throw Exception(
              'Article introuvable pour la réservation : ${item.productName}');
        }
        await _approvalTakeStock(order, pid, vid, item.quantity);
        done.add(item);
      }
    } catch (e) {
      // Rollback : restaurer les articles déjà réservés avant l'échec.
      for (final item in done) {
        final (pid, vid) = _resolveProductVariant(products, item.productId);
        if (pid == null) continue;
        await _approvalReturnStock(
            order, pid, vid, item.quantity, 'rollback réservation à choisir');
      }
      rethrow;
    }
    // Naît « Programmée » (comme une commande e-commerce normale) mais avec le
    // flag + stock réservé : l'opérateur la voit dans sa liste avec le badge
    // « À choisir » et la clôture depuis là (la transition générique ne touche
    // jamais à son stock, cf. garde-fou isApprovalSale).
    final reserved = order.copyWith(
      isApprovalSale: true,
      stockReserved:  true,
      status:         SaleStatus.scheduled,
    );
    await saveOrder(reserved);
  }

  /// Clôture une commande « à choisir sur place ». [keptByItemId] = quantité
  /// GARDÉE (vendue) par article. Les quantités retournées sont remises en
  /// stock ; les gardées restent sorties (déjà décrémentées à la réservation)
  /// et forment la vente finale (`completed`). Si rien n'est gardé → tout
  /// remis en stock et commande `cancelled`.
  Future<void> closeApprovalOrder(
      String orderId, Map<String, int> keptByItemId) async {
    final raw = _ordersBox.get(orderId);
    if (raw is! Map) return;
    final order = _mapToSaleWithStatus(Map<String, dynamic>.from(raw));
    if (!order.isApprovalSale || !order.stockReserved) return;

    final reserved = {for (final i in order.items) i.productId: i.quantity};
    final recon =
        ApprovalClosure.reconcile(reserved: reserved, kept: keptByItemId);

    // 1. Remettre en stock les quantités retournées.
    final products = AppDatabase.getProductsForShop(order.shopId);
    for (final entry in recon.returned.entries) {
      if (entry.value <= 0) continue;
      final (pid, vid) = _resolveProductVariant(products, entry.key);
      if (pid == null) continue;
      await _approvalReturnStock(
          order, pid, vid, entry.value, 'retour vente à choisir');
    }

    // 2. Vente finale = articles gardés (qty = quantité gardée).
    final keptItems = <SaleItem>[];
    for (final item in order.items) {
      final k = recon.kept[item.productId] ?? 0;
      if (k > 0) keptItems.add(item.copyWith(quantity: k));
    }

    // 3. Persister.
    final closed = keptItems.isEmpty
        ? order.copyWith(
            status:        SaleStatus.cancelled,
            stockReserved: false, // tout a été remis en stock
            cancellationReason: 'aucun article gardé sur place',
          )
        : order.copyWith(items: keptItems, status: SaleStatus.completed);
    await updateOrder(closed);
  }

  /// Annule une commande « à choisir sur place » réservée : remet en stock
  /// TOUS les articles encore portés par la commande, puis passe à `cancelled`.
  Future<void> cancelApprovalOrder(String orderId, {String? reason}) async {
    final raw = _ordersBox.get(orderId);
    if (raw is! Map) return;
    final order = _mapToSaleWithStatus(Map<String, dynamic>.from(raw));
    if (!order.isApprovalSale) return;
    if (order.stockReserved) {
      final products = AppDatabase.getProductsForShop(order.shopId);
      for (final item in order.items) {
        final (pid, vid) = _resolveProductVariant(products, item.productId);
        if (pid == null) continue;
        await _approvalReturnStock(
            order, pid, vid, item.quantity,
            reason ?? 'annulation vente à choisir');
      }
    }
    final cancelled = order.copyWith(
      status:             SaleStatus.cancelled,
      stockReserved:      false,
      cancellationReason: reason,
    );
    await updateOrder(cancelled);
  }

  /// Résout (productId, variantId) à partir de l'id stocké dans l'item de
  /// commande. L'item peut référencer soit un variantId soit un productId.
  static (String?, String) _resolveProductVariant(
      List<dynamic> products, String idInItem) {
    String? pid;
    String vid = idInItem;
    for (final p in products) {
      for (final v in p.variants) {
        if (v.id == idInItem) { pid = p.id; break; }
      }
      if (pid != null) break;
      if (p.id == idInItem) {
        pid = p.id;
        vid = p.variants.isNotEmpty
            ? (p.variants.first.id ?? idInItem)
            : idInItem;
        break;
      }
    }
    return (pid, vid);
  }

  /// Soft-delete une commande (hotfix_084).
  ///
  /// Garde-fous appelants (`DeleteSaleUseCase`) :
  ///   • statut ∈ {scheduled, processing, refused},
  ///   • `amount_paid == 0`,
  ///   • motif ≥ 10 caractères.
  ///
  /// Effets de bord :
  ///   1. Restauration de stock : par construction, les statuts éligibles
  ///      ne sont JAMAIS `completed` → en théorie le stock n'a pas été
  ///      décrémenté. On appelle quand même `_restoreOrderStock` si la
  ///      commande est dans un état où le stock a été pris (defensive ;
  ///      gère les commandes legacy mal sourcées).
  ///   2. Marquage Hive : la ligne est CONSERVÉE (pas de `box.delete`)
  ///      avec `deleted_at / deleted_by / delete_reason` peuplés.
  ///      `getOrders` la filtrera dès le prochain appel.
  ///   3. RPC Supabase via [AppDatabase.bgSoftDeleteSale] (online → call
  ///      direct, offline → enqueue + replay au retour réseau).
  ///   4. Notification listeners + recompute métriques client.
  ///
  /// Idempotente : un 2ᵉ appel sur une commande déjà supprimée écrase
  /// `deleted_at` à NOW() (acceptable — la RPC SQL est aussi idempotente
  /// et retournera `already:true`).
  Future<void> softDeleteOrder(String orderId, {
    required String reason,
    required String userId,
  }) async {
    final raw = _ordersBox.get(orderId);
    if (raw == null) return;
    final map = Map<String, dynamic>.from(raw);
    final shopId   = map['shop_id']   as String?;
    final clientId = map['client_id'] as String?;

    // Defensive : si l'état actuel est `completed`, on restaure quand
    // même le stock avant de marquer supprimé. Ne devrait pas se produire
    // (le use case bloque en amont) mais protège contre les rejeux et
    // les commandes legacy.
    final wasCompleted = (map['status'] as String?) == 'completed';
    if (wasCompleted) {
      final order = _mapToSaleWithStatus(map);
      await _restoreOrderStock(order);
    }

    // Marquer le soft-delete dans Hive.
    final now = DateTime.now().toUtc().toIso8601String();
    map['deleted_at']    = now;
    map['deleted_by']    = userId;
    map['delete_reason'] = reason;
    await _ordersBox.put(orderId, map);

    if (shopId != null) AppDatabase.notifyOrderChange(shopId);
    if (shopId != null && clientId != null && clientId.isNotEmpty) {
      await AppDatabase.refreshClientMetrics(clientId, shopId);
    }

    // Annuler les notifications de livraison programmées.
    await DeliveryReminderService.cancelFor(orderId);

    // Pousser à Supabase via la RPC `delete_sale` (online direct ou
    // enqueue offline).
    await AppDatabase.bgSoftDeleteSale(
      orderId:  orderId,
      userId:   userId,
      reason:   reason,
    );
  }

  // ── helpers privés ────────────────────────────────────────────────────────

  Map<String, dynamic> _saleToMap(Sale sale) => {
    'shop_id':        sale.shopId,
    'discount_amount': sale.discountAmount,
    'payment_method': sale.paymentMethod.name,
    'client_id':      sale.clientId,
    'client_phone':   sale.clientPhone,
    'created_at':     sale.createdAt.toIso8601String(),
    'items':          sale.items.map(_itemToMap).toList(),
    'synced_to_cloud': false,
  };

  Map<String, dynamic> _itemToMap(SaleItem i) => {
    'product_id':   i.productId,
    'product_name': i.productName,
    'unit_price':   i.unitPrice,
    'price_buy':    i.priceBuy,
    'custom_price': i.customPrice,
    'quantity':     i.quantity,
    'discount':     i.discount,
    'image_url':    i.imageUrl,
    'variant_name': i.variantName,
  };

  /// GF-5 — Anti-doublon retour. Retourne `true` si au moins un mouvement
  /// `return_client_good` ou `return_defective` existe avec
  /// `reference_id = orderId` dans `stock_movements`. Si [variantId] est
  /// fourni, le check est restreint à cette variante précise (utile pour
  /// gérer les retours partiels article-par-article).
  ///
  /// Lecture Hive uniquement → fonctionne 100% offline. Côté SQL, la
  /// même règle pourra être ré-imposée via une RPC `create_return`
  /// dans une future migration si besoin (pas pertinent ici : pas de
  /// table `stock_returns`, le journal est `stock_movements`).
  bool hasExistingReturn(String orderId, {String? variantId}) {
    if (!Hive.isBoxOpen(HiveBoxes.stockMovements)) return false;
    for (final raw in HiveBoxes.stockMovementsBox.values) {
      try {
        final m = Map<String, dynamic>.from(raw);
        if (m['reference_id'] != orderId) continue;
        if (variantId != null && m['variant_id'] != variantId) continue;
        final type = m['type'] as String? ?? '';
        if (type == 'return_client_good' || type == 'return_defective') {
          return true;
        }
      } catch (_) {}
    }
    return false;
  }

  /// Détail du retour existant pour `orderId` : id du 1er mouvement de
  /// retour + sa date. Utilisé pour afficher une référence parlante dans
  /// le dialog d'anti-doublon (« Retour déjà enregistré le 18/05 à 14:32 »).
  /// Retourne null si aucun retour n'existe.
  ({String movementId, DateTime createdAt})? existingReturnInfo(
      String orderId) {
    if (!Hive.isBoxOpen(HiveBoxes.stockMovements)) return null;
    DateTime? bestAt;
    String? bestId;
    for (final raw in HiveBoxes.stockMovementsBox.values) {
      try {
        final m = Map<String, dynamic>.from(raw);
        if (m['reference_id'] != orderId) continue;
        final type = m['type'] as String? ?? '';
        if (type != 'return_client_good' && type != 'return_defective') {
          continue;
        }
        final ts = DateTime.tryParse(m['created_at']?.toString() ?? '');
        if (ts == null) continue;
        if (bestAt == null || ts.isBefore(bestAt)) {
          bestAt = ts;
          bestId = m['id'] as String?;
        }
      } catch (_) {}
    }
    if (bestId == null || bestAt == null) return null;
    return (movementId: bestId, createdAt: bestAt);
  }

  /// Compatible avec les clés Hive courtes ET Supabase longues
  Sale _mapToSale(Map<String, dynamic> m) {
    // discount_amount (Supabase) ou discount (Hive ancien)
    final discount = (m['discount_amount'] ?? m['discount'] ?? 0) as num;
    // payment_method (Supabase) ou payment (Hive ancien)
    final payStr = (m['payment_method'] ?? m['payment'] ?? 'cash') as String;
    final payment = PaymentMethod.values
        .firstWhere((e) => e.name == payStr,
        orElse: () => PaymentMethod.cash);

    // items : liste de maps (Hive ou Supabase jsonb)
    final rawItems = m['items'];
    final items = <SaleItem>[];
    if (rawItems is List) {
      for (final i in rawItems) {
        try {
          final map = Map<String, dynamic>.from(i as Map);
          // Les commandes WEB (place_public_order) stockent
          // {product_id: parentId, variant_id: variantId} séparés. Les
          // commandes POS multi-variant stockent product_id = variantId
          // (cf. product_grid_widget). Pour rester cohérent côté domain
          // (SaleItem.productId = id matchable via variantToParent dans
          // DeliveryMessageBuilder), on prend variant_id en priorité s'il
          // est renseigné. Sinon fallback sur product_id. Sans ce
          // mapping, le lien delivery d'une commande web multi-variant
          // omettait l'index variante dans `stock=` → la page catalogue
          // filtrait toutes les variantes et affichait « Les produits
          // partagés ne sont plus disponibles ».
          final rawVariantId =
              (map['variant_id'] as String?)?.trim() ?? '';
          final productIdValue = rawVariantId.isNotEmpty
              ? rawVariantId
              : ((map['product_id'] ?? '') as String);
          items.add(SaleItem(
            productId:   productIdValue,
            productName: (map['product_name'] ?? map['name'] ?? '') as String,
            unitPrice:   ((map['unit_price'] ?? map['price'] ?? 0) as num)
                .toDouble(),
            customPrice: (map['custom_price'] as num?)?.toDouble(),
            priceBuy:    ((map['price_buy'] ?? 0) as num).toDouble(),
            quantity:    (map['quantity'] ?? map['qty'] ?? 1) as int,
            discount:    ((map['discount'] ?? 0) as num).toDouble(),
            imageUrl:    map['image_url'] as String?,
            variantName: map['variant_name'] as String?,
          ));
        } catch (e) {
          debugPrint('[DS] item parse error: $e');
        }
      }
    }

    // Frais de commande
    final rawFees = m['fees'] as List?;
    final fees = rawFees
        ?.map((f) => Map<String, dynamic>.from(f as Map))
        .toList() ?? <Map<String, dynamic>>[];

    return Sale(
      shopId:        m['shop_id'] as String,
      discountAmount: discount.toDouble(),
      paymentMethod:  payment,
      clientId:      m['client_id'] as String?,
      clientPhone:   m['client_phone'] as String?,
      createdAt:     DateTime.tryParse(
          m['created_at']?.toString() ?? '') ?? DateTime.now(),
      items:         items,
      fees:          fees,
      createdByUserId: m['created_by_user_id'] as String?,
      deliveryCity:    m['delivery_city']    as String?,
      deliveryAddress: m['delivery_address'] as String?,
      shipmentCity:    m['shipment_city']    as String?,
      shipmentAgency:  m['shipment_agency']  as String?,
      shipmentHandler: m['shipment_handler'] as String?,
      cancellationReason: m['cancellation_reason'] as String?,
      rescheduleReason:   m['reschedule_reason']   as String?,
      source:             (m['source'] as String?) ?? 'pos',
      amountPaid:         (m['amount_paid'] as num?)?.toDouble() ?? 0,
      paymentStatus:      PaymentStatusX.fromKey(
                              m['payment_status'] as String?),
      idempotencyKey:     m['idempotency_key'] as String?, // GF-1
      // Vente « à choisir sur place » (lecture tolérante : colonnes absentes
      // sur les commandes legacy → false).
      isApprovalSale:     (m['is_approval_sale'] as bool?) ?? false,
      stockReserved:      (m['stock_reserved'] as bool?) ?? false,
    );
  }

  Sale _mapToSaleWithStatus(Map<String, dynamic> m) {
    final base = _mapToSale(m);
    final statusStr = m['status'] as String? ?? 'scheduled';
    final status = SaleStatus.values.firstWhere(
            (s) => s.name == statusStr, orElse: () => SaleStatus.scheduled);
    // Lire les frais de commande (compatible anciennes commandes sans frais)
    final rawFees = m['fees'] as List?;
    final fees = rawFees
        ?.map((f) => Map<String, dynamic>.from(f as Map))
        .toList() ?? <Map<String, dynamic>>[];

    return base.copyWith(
      id:           m['id'] as String?,
      status:       status,
      taxRate:      (m['tax_rate'] as num?)?.toDouble() ?? 0,
      clientName:   m['client_name'] as String?,
      notes:        m['notes'] as String?,
      fees:         fees,
      scheduledAt:  m['scheduled_at'] != null
          ? DateTime.tryParse(m['scheduled_at'] as String)
          : null,
      deliveryMode:       DeliveryModeX.fromKey(
                          m['delivery_mode'] as String?),
      deliveryLocationId: m['delivery_location_id'] as String?,
      deliveryPersonName: m['delivery_person_name'] as String?,
      // Soft-delete (hotfix_084). Lecture tolérante : Supabase et Hive
      // peuvent ne pas exposer ces colonnes sur les commandes legacy.
      deletedAt: m['deleted_at'] != null
          ? DateTime.tryParse(m['deleted_at'].toString())
          : null,
      deletedBy:    m['deleted_by']    as String?,
      deleteReason: m['delete_reason'] as String?,
    );
  }
}