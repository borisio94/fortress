import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../../../core/storage/hive_boxes.dart';
import '../../../../core/services/stock_service.dart';
import '../../../../core/services/delivery_reminder_service.dart';
import '../../../../core/database/app_database.dart';
import '../../domain/entities/sale.dart';
import '../../domain/entities/sale_item.dart';

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
      'created_at':     order.createdAt.toUtc().toIso8601String(),
      'completed_at':   completedAt,
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
      'created_at':     order.createdAt.toUtc().toIso8601String(),
      'completed_at':   completedAt,
      'synced_to_cloud': false,
      'fees':           order.fees,
      'items': order.items.map((i) => {
        'product_id':   i.productId,
        'product_name': i.productName,
        'unit_price':   i.unitPrice,
        'price_buy':    i.priceBuy,
        'custom_price': i.customPrice,
        'quantity':     i.quantity,
        'discount':     i.discount,
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
  Sale? getOrderById(String orderId) {
    try {
      if (!Hive.isBoxOpen(HiveBoxes.orders)) return null;
      final raw = _ordersBox.get(orderId);
      if (raw == null) return null;
      return _mapToSaleWithStatus(Map<String, dynamic>.from(raw as Map));
    } catch (_) {
      return null;
    }
  }

  /// Récupérer toutes les commandes d'une boutique
  List<Sale> getOrders(String shopId) {
    try {
      if (!Hive.isBoxOpen(HiveBoxes.orders)) return [];
      return _ordersBox.values
          .map((m) {
        try {
          return _mapToSaleWithStatus(
              Map<String, dynamic>.from(m as Map));
        } catch (_) { return null; }
      })
          .whereType<Sale>()
          .where((s) => s.shopId == shopId)
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
      'created_at':     order.createdAt.toUtc().toIso8601String(),
      'completed_at':   completedAt,
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
      'completed_at':   completedAt,
      'fees':           order.fees,
      'items': order.items.map((i) => {
        'product_id':   i.productId,
        'product_name': i.productName,
        'unit_price':   i.unitPrice,
        'price_buy':    i.priceBuy,
        'custom_price': i.customPrice,
        'quantity':     i.quantity,
        'discount':     i.discount,
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
    final map = Map<String, dynamic>.from(raw as Map);
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

  /// Marque une commande comme "annulée par le client" : statut → cancelled
  /// + persiste la raison fournie par l'opérateur.
  /// Effets de bord (notifs, métriques client, sync Supabase) délégués à
  /// updateOrderStatus pour rester cohérent.
  Future<void> cancelOrderWithReason(String orderId, String reason) async {
    final raw = _ordersBox.get(orderId);
    if (raw == null) return;
    final map = Map<String, dynamic>.from(raw as Map);
    map['cancellation_reason'] = reason.trim();
    await _ordersBox.put(orderId, map);
    await updateOrderStatus(orderId, SaleStatus.cancelled);
  }

  /// Reprogramme une commande "en cours" : statut → scheduled, met à jour
  /// la date de livraison, persiste la raison de la reprogrammation. La
  /// présence de `reschedule_reason` sert ensuite de marqueur visuel
  /// "commande reprogrammée" dans la liste.
  Future<void> rescheduleOrder(
      String orderId, DateTime newDate, String reason) async {
    final raw = _ordersBox.get(orderId);
    if (raw == null) return;
    final map = Map<String, dynamic>.from(raw as Map);
    map['scheduled_at']      = newDate.toUtc().toIso8601String();
    map['reschedule_reason'] = reason.trim();
    await _ordersBox.put(orderId, map);
    await updateOrderStatus(orderId, SaleStatus.scheduled);
  }

  Future<void> updateOrderStatus(String orderId, SaleStatus status) async {
    final raw = _ordersBox.get(orderId);
    if (raw == null) return;
    final map = Map<String, dynamic>.from(raw as Map);

    // Lire l'ancien statut AVANT modification pour gérer la compensation
    // de stock si on traverse la frontière "completed".
    final oldStatusStr = map['status'] as String? ?? 'scheduled';
    final oldStatus = SaleStatus.values.firstWhere(
        (s) => s.name == oldStatusStr, orElse: () => SaleStatus.scheduled);

    map['status'] = status.name;
    // Stamp completed_at à la transition → completed (garder si déjà stampé)
    if (status == SaleStatus.completed) {
      map['completed_at'] ??= DateTime.now().toUtc().toIso8601String();
    } else {
      map['completed_at'] = null;
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

  /// Supprimer une commande (Hive + Supabase via offline queue).
  /// Si la commande était liée à un client, on recalcule immédiatement ses
  /// métriques (totalSpent / totalOrders / lastVisitAt) pour que la
  /// suppression se reflète côté CRM sans attendre.
  /// Si la commande était `completed`, le stock doit être restauré : sinon
  /// les unités vendues restent décomptées alors que la commande disparaît.
  Future<void> deleteOrder(String orderId) async {
    final raw = _ordersBox.get(orderId);
    final shopId   = raw is Map ? raw['shop_id']   as String? : null;
    final clientId = raw is Map ? raw['client_id'] as String? : null;
    // Restauration de stock si la commande était completed.
    if (raw is Map) {
      final map = Map<String, dynamic>.from(raw);
      final wasCompleted = (map['status'] as String?) == 'completed';
      if (wasCompleted) {
        final order = _mapToSaleWithStatus(map);
        await _restoreOrderStock(order);
      }
    }
    await _ordersBox.delete(orderId);
    if (shopId != null) AppDatabase.notifyOrderChange(shopId);
    if (shopId != null && clientId != null && clientId.isNotEmpty) {
      await AppDatabase.refreshClientMetrics(clientId, shopId);
    }
    // Supprimer sur Supabase (immédiat si online, sinon queued)
    AppDatabase.bgDeleteOrder(orderId);
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
    'variant_name': i.variantName,
  };

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
          items.add(SaleItem(
            productId:   (map['product_id'] ?? '') as String,
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
    );
  }
}