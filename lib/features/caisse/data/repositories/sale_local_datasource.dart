import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../../../core/storage/hive_boxes.dart';
import '../../../../core/services/stock_service.dart';
import '../../../../core/services/activity_log_service.dart';
import '../../../../core/services/delivery_reminder_service.dart';
import '../../../../core/services/partner_ledger_service.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/utils/uuid.dart';
import '../../domain/entities/sale.dart';
import '../../domain/entities/sale_item.dart';
import '../../domain/approval_closure.dart';
import '../../domain/stock_engagement.dart';

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
    // UUID v4 (Random.secure()) : l'identifiant horodaté était devinable par
    // énumération — il servait de seul secret au lien de suivi public — et
    // deux commandes de la même milliseconde s'écrasaient au `put` ci-dessous,
    // qui ne vérifie aucune existence préalable.
    final id = order.id ?? Uuid.v4();

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
      'discount_reason': order.discountReason,
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
      'delivery_quartier':    order.deliveryQuartier,
      'delivery_zone':        order.deliveryZone,
      'delivery_price':       order.deliveryPrice?.round(),
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
      // Module restaurant (hotfix_137). Doit figurer dans les QUATRE maps
      // (saveOrder+updateOrder x hive+supa) : updateOrder reconstruit la
      // map depuis l'entite sans merge, donc une omission effacerait la
      // table au premier ajout de plat a une commande en cours.
      'table_id':         order.tableId,
      'tab_label':        order.tabLabel,
      'covers':           order.covers,
      'order_type':       order.orderType,
      'sent_to_kitchen':  order.sentToKitchen,
      'kitchen_ready':    order.kitchenReady,
      'served':           order.served,
      'finished':         order.finished,
      'fees':           order.fees,
      // GF-1 : clé d'idempotence du panier — persistée en Hive ET pushée
      // à Supabase pour bénéficier de l'UNIQUE constraint (hotfix_080).
      'idempotency_key': order.idempotencyKey,
      // Jeton de suivi (hotfix_171) : présent en Hive UNIQUEMENT. La colonne
      // appartient au serveur, qui la remplit par DEFAULT ; l'omettre de la
      // map Supabase garantit qu'un upsert client ne l'écrase jamais.
      'tracking_token':  order.trackingToken,
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
        'modifiers':    i.modifiers,
      }).toList(),
    };

    // ── Map Supabase (colonnes exactes de la table orders) ────────
    final supaMap = <String, dynamic>{
      'id':             id,
      'shop_id':        order.shopId,
      'status':         order.status.name,
      'discount_amount': order.discountAmount,
      'discount_reason': order.discountReason,
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
      'delivery_quartier':    order.deliveryQuartier,
      'delivery_zone':        order.deliveryZone,
      'delivery_price':       order.deliveryPrice?.round(),
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
      // Module restaurant (hotfix_137). Doit figurer dans les QUATRE maps
      // (saveOrder+updateOrder x hive+supa) : updateOrder reconstruit la
      // map depuis l'entite sans merge, donc une omission effacerait la
      // table au premier ajout de plat a une commande en cours.
      'table_id':         order.tableId,
      'tab_label':        order.tabLabel,
      'covers':           order.covers,
      'order_type':       order.orderType,
      'sent_to_kitchen':  order.sentToKitchen,
      'kitchen_ready':    order.kitchenReady,
      'served':           order.served,
      'finished':         order.finished,
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
        'modifiers':    i.modifiers,
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

  /// Créances clients regroupées par `clientId`. Une CRÉANCE = commande
  /// COMPLÉTÉE (livrée) dont le client n'a pas tout payé (`amountDue > 0`) —
  /// c'est le résultat d'une vente à crédit. Les commandes encore ouvertes
  /// (programmée/en cours) ne comptent pas : leur solde n'est pas encore une
  /// dette, juste un acompte en attente.
  Map<String, double> clientDebtsByClient(String shopId) {
    final res = <String, double>{};
    for (final o in getOrders(shopId)) {
      if (o.status != SaleStatus.completed) continue;
      final due = o.amountDue;
      if (due <= 0) continue;
      final cid = o.clientId;
      if (cid == null || cid.isEmpty) continue;
      res[cid] = (res[cid] ?? 0) + due;
    }
    return res;
  }

  /// Créance d'un client donné (0 s'il n'a aucune commande à crédit).
  double clientDebt(String shopId, String clientId) =>
      clientDebtsByClient(shopId)[clientId] ?? 0;

  /// Total des créances clients de la boutique — inclut les ventes à crédit
  /// SANS client rattaché (créance anonyme : argent dû quand même).
  double totalClientDebts(String shopId) {
    double t = 0;
    for (final o in getOrders(shopId)) {
      if (o.status == SaleStatus.completed) t += o.amountDue;
    }
    return t;
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
      // Jeton de suivi (hotfix_171). INDISPENSABLE ici : cette map REMPLACE
      // intégralement la ligne Hive (put sans merge) — c'est déjà ainsi que
      // `source` et `idempotency_key` se perdent à chaque modification de
      // commande. Sans cette ligne, modifier une commande lui ferait perdre
      // son jeton, donc son lien de suivi.
      'tracking_token': order.trackingToken,
      'shop_id':        order.shopId,
      'status':         order.status.name,
      'discount_amount': order.discountAmount,
      'discount_reason': order.discountReason,
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
      'delivery_quartier':    order.deliveryQuartier,
      'delivery_zone':        order.deliveryZone,
      'delivery_price':       order.deliveryPrice?.round(),
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
      // Module restaurant (hotfix_137). Doit figurer dans les QUATRE maps
      // (saveOrder+updateOrder x hive+supa) : updateOrder reconstruit la
      // map depuis l'entite sans merge, donc une omission effacerait la
      // table au premier ajout de plat a une commande en cours.
      'table_id':         order.tableId,
      'tab_label':        order.tabLabel,
      'covers':           order.covers,
      'order_type':       order.orderType,
      'sent_to_kitchen':  order.sentToKitchen,
      'kitchen_ready':    order.kitchenReady,
      'served':           order.served,
      'finished':         order.finished,
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
        'modifiers':    i.modifiers,
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
      'discount_reason': order.discountReason,
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
      'delivery_quartier':    order.deliveryQuartier,
      'delivery_zone':        order.deliveryZone,
      'delivery_price':       order.deliveryPrice?.round(),
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
      // Module restaurant (hotfix_137). Doit figurer dans les QUATRE maps
      // (saveOrder+updateOrder x hive+supa) : updateOrder reconstruit la
      // map depuis l'entite sans merge, donc une omission effacerait la
      // table au premier ajout de plat a une commande en cours.
      'table_id':         order.tableId,
      'tab_label':        order.tabLabel,
      'covers':           order.covers,
      'order_type':       order.orderType,
      'sent_to_kitchen':  order.sentToKitchen,
      'kitchen_ready':    order.kitchenReady,
      'served':           order.served,
      'finished':         order.finished,
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
        'modifiers':    i.modifiers,
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
    // H3 — verrou de routage stock. Une fois le stock engagé sur un
    // emplacement (commande `completed`, OU vente à choisir réservée), changer
    // le mode/emplacement de livraison ferait diverger le décrément (pris à un
    // endroit) de la restitution future (rendue ailleurs) → fuite asymétrique.
    // On fige donc mode + location_id dans ces cas ; les autres champs
    // (personne, ville, adresse, agence…) restent modifiables.
    final committed = (map['status'] as String?) == 'completed'
        || ((map['is_approval_sale'] as bool? ?? false)
            && (map['stock_reserved'] as bool? ?? false));
    if (!committed) {
      map['delivery_mode']        = mode?.key;
      map['delivery_location_id'] = locationId;
    }
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
    // Update CIBLÉ (champs livraison/paiement uniquement) — NE touche PAS
    // `status` : sinon ce push (portant l'ancien statut), en course avec le
    // `updateOrderStatus` qui suit, pouvait faire régresser le statut
    // (scheduled → processing → … → scheduled).
    final fields = <String, dynamic>{
      'delivery_person_name': map['delivery_person_name'],
      'delivery_city':        map['delivery_city'],
      'delivery_address':     map['delivery_address'],
      'shipment_city':        map['shipment_city'],
      'shipment_agency':      map['shipment_agency'],
      'shipment_handler':     map['shipment_handler'],
      if (paymentMethod != null) 'payment_method': map['payment_method'],
      if (!committed) 'delivery_mode':        map['delivery_mode'],
      if (!committed) 'delivery_location_id': map['delivery_location_id'],
      if (scheduledAt != null) 'scheduled_at': map['scheduled_at'],
    };
    AppDatabase.bgUpdateOrder(orderId, fields);
  }

  /// Réassigne UNIQUEMENT l'emplacement + le mode de livraison d'une commande
  /// (« transférer la commande à un partenaire »). Contrairement à
  /// [updateOrderDelivery], ne touche QU'À `delivery_mode` +
  /// `delivery_location_id` — préserve personne/ville/adresse/expédition.
  /// Respecte le verrou H3 (refuse si la commande est `completed` ou une vente
  /// à choisir déjà réservée — re-router à ce stade ferait diverger le
  /// décrément/restitution de stock). No-op si commande absente ou engagée.
  Future<void> reassignDelivery(String orderId,
      {required DeliveryMode mode, required String locationId}) async {
    final raw = _ordersBox.get(orderId);
    if (raw == null) return;
    final map = Map<String, dynamic>.from(raw);
    final committed = (map['status'] as String?) == 'completed'
        || ((map['is_approval_sale'] as bool? ?? false)
            && (map['stock_reserved'] as bool? ?? false));
    if (committed) return; // verrou H3 : ne pas re-router une commande engagée
    map['delivery_mode']        = mode.key;
    map['delivery_location_id'] = locationId;
    await _ordersBox.put(orderId, map);
    final shopId = map['shop_id'] as String?;
    if (shopId != null) AppDatabase.notifyOrderChange(shopId);
    final supaMap = Map<String, dynamic>.from(map)..remove('image_url');
    AppDatabase.bgWriteOrder(supaMap);
  }

  /// Vérifie qu'un emplacement (partenaire) a ASSEZ de stock pour TOUS les
  /// articles d'une commande : somme des quantités par variante vs le
  /// `StockLevel` de cette location. Retourne `(ok, missing)` où `missing`
  /// est le nom du 1er article manquant (null si tout est couvert). Sert à
  /// bloquer le transfert vers un partenaire qui n'a pas le stock.
  ({bool ok, String? missing}) locationCanFulfill(
      Sale order, String locationId) {
    final products = AppDatabase.getProductsForShop(order.shopId);
    final required = <String, int>{};   // variantId → quantité requise
    final labels   = <String, String>{};
    for (final item in order.items) {
      final (pid, vid) = _resolveProductVariant(products, item.productId);
      if (pid == null) return (ok: false, missing: item.productName);
      required.update(vid, (q) => q + item.quantity,
          ifAbsent: () => item.quantity);
      labels[vid] = item.productName;
    }
    for (final entry in required.entries) {
      final avail =
          AppDatabase.getStockLevel(entry.key, locationId)?.stockAvailable ?? 0;
      if (avail < entry.value) {
        return (ok: false, missing: labels[entry.key]);
      }
    }
    return (ok: true, missing: null);
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
  ///
  /// Renvoie `true` si l'encaissement a bien été écrit, `false` sinon.
  ///
  /// Ce retour existe parce que la méthode peut renoncer SANS rien signaler —
  /// commande introuvable. L'appelant, lui, annonçait « Acompte enregistré »
  /// dans tous les cas : l'opérateur encaissait de l'argent, lisait une
  /// confirmation, et rien n'était écrit. Un échec muet sur un mouvement
  /// d'argent est le pire des silences.
  Future<bool> recordPayment(String orderId, double newAmountPaid) async {
    final raw = _ordersBox.get(orderId);
    if (raw == null) return false;
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
    // Update CIBLÉ (paiement uniquement) — NE touche PAS `status` (sinon ce
    // push pouvait, en course avec un changement de statut concomitant, faire
    // régresser la commande).
    AppDatabase.bgUpdateOrder(orderId, {
      'amount_paid':    map['amount_paid'],
      'payment_status': map['payment_status'],
    });
    return true;
  }

  /// Fixe le prix de livraison d'une commande (cas « frais à fixer » des
  /// commandes web dont le quartier n'était pas répertorié). Met à jour
  /// `delivery_price` (Hive + Supabase) et notifie. Le total est recalculé à
  /// la lecture (Sale.total inclut deliveryPrice). No-op si commande absente.
  Future<void> setDeliveryPrice(String orderId, int price) async {
    final raw = _ordersBox.get(orderId);
    if (raw == null) return;
    final map = Map<String, dynamic>.from(raw);
    map['delivery_price'] = price;
    await _ordersBox.put(orderId, map);
    final shopId = map['shop_id'] as String?;
    if (shopId != null) AppDatabase.notifyOrderChange(shopId);
    final supaMap = Map<String, dynamic>.from(map)..remove('image_url');
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
    // C1 — quand `true`, on NE rejoue PAS la compensation de stock générique
    // (restore/décrément). Utilisé par la page Retours qui a déjà restitué le
    // stock ligne-à-ligne via StockService.returnGood/returnDefective : sans
    // ce drapeau, le passage à `refunded` recréditait EN PLUS la quantité
    // totale de la commande → double-crédit.
    bool skipStockCompensation = false,
    // VENTE À CRÉDIT — montant TOTAL réellement encaissé du client à la
    // clôture. Si fourni (non null) lors d'un passage à `completed`, on
    // l'utilise tel quel au lieu de forcer « entièrement payé » : un montant
    // < total laisse une créance client (payment_status partial/unpaid). Si
    // null, comportement historique (force amount_paid = total, paid).
    double? amountPaidOnComplete,
    // ARG-2 — `true` quand c'est le PARTENAIRE-LIVREUR qui a encaissé le
    // client, sans avoir encore versé à la boutique. Sans cette information,
    // la clôture écrivait `paid` : la commande passait pour soldée côté
    // boutique alors que l'argent était ailleurs. L'appelant la tient du
    // sheet de clôture (`CollectedBy`), seul endroit où la question est posée.
    bool collectedByPartner = false,
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
    } else if (status != SaleStatus.refunded) {
      // FIX 1 — un remboursement CONSERVE la date d'encaissement d'origine
      // (completed_at) : la vente a bien eu lieu, les rapports/CA doivent
      // garder cette date. On n'efface completed_at que pour un retour vers un
      // etat non finalise (cas defensif : l'automate n'autorise de toute facon
      // que completed -> refunded en sortie de completed).
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
      final total = fresh.total;
      if (amountPaidOnComplete != null) {
        // VENTE À CRÉDIT — on respecte le montant réellement encaissé. Un
        // reste > 0 devient une créance client (partial/unpaid) au lieu
        // d'être effacé. Capé à [0, total] par sécurité.
        final paid = amountPaidOnComplete.clamp(0, total).toDouble();
        map['amount_paid']    = paid;
        map['payment_status'] = PaymentStatusX.fromAmount(paid, total).key;
      } else {
        // Aucun montant transmis = le client a tout réglé. Reste à savoir À
        // QUI : `amountPaidOnComplete` n'est renseigné que lorsque la BOUTIQUE
        // encaisse, si bien que ce chemin couvre AUSSI le cas « le partenaire
        // a encaissé » — qui s'écrivait jusqu'ici `paid`, comme si la boutique
        // avait l'argent en main.
        //
        // `amount_paid` reste au total dans les deux cas : la somme a bien été
        // perçue, seul son porteur diffère. La remettre à zéro ferait
        // réapparaître une créance CLIENT qui n'existe pas.
        map['amount_paid']    = total;
        map['payment_status'] = collectedByPartner
            ? PaymentStatus.paidByPartner.key
            : PaymentStatus.paid.key;
      }
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

    // ── Remboursement → la créance partenaire disparaît avec la vente ────
    //
    // Une commande encaissée PAR un partenaire crée une créance
    // `saleCollected` à la clôture. Remboursée au client, cette créance n'a
    // plus d'objet : le partenaire était redevable du produit d'une vente qui
    // n'existe plus. Sans ce retrait, il restait affiché comme débiteur
    // indéfiniment — créance fantôme, jamais soldable autrement qu'à la main.
    //
    // `keepReceived: false` — purge TOTALE — et NON `true`, et ce n'est pas
    // un détail. Avec `true`, un `remittance` déjà enregistré survivrait
    // seul : partenaire encaisse 10 000 (`saleCollected` +10 000), reverse
    // (`remittance` −10 000), solde 0. Retirer le seul `saleCollected`
    // laisserait −10 000, soit « la boutique doit 10 000 au partenaire ».
    // Faux : il a rendu l'argent, la boutique a remboursé le client de sa
    // poche, le partenaire est quitte. Les deux écritures s'annulent, elles
    // partent ensemble.
    //
    // La trace du versement reste lisible dans le journal d'activité et
    // l'historique des mouvements ; le livre partenaire, lui, ne doit porter
    // que des soldes vrais.
    //
    // Placé ici plutôt que dans la page Retours : `updateOrderStatus` est le
    // SEUL site d'écriture du statut (l.773), et les deux chemins qui peuvent
    // poser `refunded` — menu d'évènements et page Retours — y passent tous
    // les deux. Un correctif local n'aurait couvert que l'un des deux.
    if (status == SaleStatus.refunded
        && oldStatus != SaleStatus.refunded
        && shopId != null) {
      await PartnerLedgerService.removeForOrder(shopId, orderId,
          keepReceived: false);
    }

    // ── Frais de livraison → dette envers le partenaire livreur ──────────
    // À la clôture (completed) d'une commande livrée par un PARTENAIRE avec
    // des frais de livraison, on enregistre ces frais comme une dette de la
    // boutique envers ce partenaire (écriture `deliveryOwed`). Ils sont ainsi
    // retranchés du versement attendu du partenaire (livre partenaire) — le
    // partenaire garde sa course. Idempotent (syncOrderDeliveryFee remplace
    // l'écriture existante de la commande).
    if (status == SaleStatus.completed
        && oldStatus != SaleStatus.completed
        && shopId != null) {
      final ord = _mapToSaleWithStatus(map);
      final dp = ord.deliveryPrice ?? 0;
      if (ord.deliveryMode == DeliveryMode.partner
          && (ord.deliveryLocationId ?? '').isNotEmpty
          && dp > 0) {
        await PartnerLedgerService.syncOrderDeliveryFee(
          shopId:            ord.shopId,
          partnerLocationId: ord.deliveryLocationId!,
          orderId:           orderId,
          feesTotal:         dp,
        );
      }
    }

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

    // C1 — l'appelant a déjà compensé le stock lui-même (page Retours :
    // returnGood/returnDefective ligne-à-ligne). On saute la compensation
    // générique pour ne pas double-créditer.
    if (skipStockCompensation) return;

    // NB : le filtrage des articles non suivis en stock (`track_stock`,
    // hotfix_138) se fait par LIGNE dans `_decrementOrderStock` /
    // `_restoreOrderStock`, et non ici par commande. Une même commande peut
    // mélanger un plat cuisiné (non suivi) et une bouteille (suivie) — un
    // court-circuit au niveau de la commande les traiterait à tort de la
    // même façon. Remplace le filtre par canal `order_type = 'dine_in'`.

    // H1(b) — vente « à choisir sur place » ENCORE réservée passée à
    // cancelled/refused par une voie GÉNÉRIQUE (cancelOrderWithReason / menu
    // statut), hors `cancelApprovalOrder`. Aucune frontière `completed` n'est
    // franchie → le bloc ci-dessous retournerait sans rien faire → le stock
    // réservé resterait sorti (fuite). On le restitue ici puis on éteint le
    // flag.
    if (shopId != null
        && (status == SaleStatus.cancelled || status == SaleStatus.refused)) {
      final ord = _mapToSaleWithStatus(map);
      if (ord.isApprovalSale && ord.stockReserved) {
        final products = AppDatabase.getProductsForShop(ord.shopId);
        for (final item in ord.items) {
          final (pid, vid) = _resolveProductVariant(products, item.productId);
          if (pid == null) {
            _logRestockMiss(ord, item.productId, item.quantity,
                'annulation/refus générique vente à choisir');
            continue;
          }
          await _approvalReturnStock(ord, pid, vid, item.quantity,
              'restitution ${status.name} vente à choisir');
        }
        map['stock_reserved'] = false;
        await _ordersBox.put(orderId, map);
        final supa = Map<String, dynamic>.from(map)..remove('image_url');
        AppDatabase.bgWriteOrder(supa);
        return;
      }
    }

    // ── Compensation de stock selon la transition ──
    // MODÈLE « stock engagé » : le stock sort des disponibles dès que la
    // commande est `processing` (partie en livraison) OU `completed`
    // (encaissée), et revient quand elle régresse en deçà. Cf.
    // `StockEngagement` (logique pure testée). Le flag persistant
    // `stock_reserved` évite tout double-mouvement et reste rétro-compatible
    // avec les données antérieures (jamais flaggées).
    if (oldStatus == status || shopId == null) return;
    final order = _mapToSaleWithStatus(map);
    final reserved = map['stock_reserved'] == true;

    // Vente « à choisir sur place » : le stock est géré EXPLICITEMENT par
    // reserveApprovalOrder / closeApprovalOrder / cancelApprovalOrder. On NE
    // laisse donc PAS la logique générique agir, SAUF le remboursement d'une
    // vente déjà complétée (completed → autre) : là, il faut restituer le
    // stock des articles GARDÉS (post-clôture la commande ne porte plus que
    // ceux-ci, et `stockReserved` est déjà false). H1(a).
    if (order.isApprovalSale) {
      if (oldStatus == SaleStatus.completed && status != SaleStatus.completed) {
        await _restoreOrderStock(order);
      }
      return;
    }

    final decision = StockEngagement.decide(
      oldStatus: oldStatus, newStatus: status, reserved: reserved);
    // `decide` est PUR et le reste : il dit ce qu'il FAUDRAIT faire, sans
    // rien savoir de ce qui se passera. C'est ici, après la tentative, que
    // le drapeau se décide — sur un résultat, plus sur une intention.
    var reservedToPersist = decision.reserved;
    if (decision.action == StockAction.decrement) {
      final moved = await _decrementOrderStock(order);
      // STK-1 — le drapeau ne vaut `true` que si AU MOINS un article est
      // réellement sorti. Rien n'est sorti → rien n'est engagé → une
      // annulation ne restituera rien, au lieu de créer du stock.
      reservedToPersist = moved.isNotEmpty;
      if (moved.isEmpty && order.items.isNotEmpty) {
        // Synthèse : chaque article a déjà été tracé individuellement par
        // `_logStockDecrementMiss`, mais l'échec TOTAL mérite sa propre
        // entrée — c'est lui qui explique qu'une commande passe à
        // `completed` sans qu'aucun stock n'ait bougé.
        ActivityLogService.log(
          action:      'stock_decrement_none',
          targetType:  'sale',
          targetId:    order.id,
          targetLabel: order.clientName ?? 'Commande',
          shopId:      order.shopId,
          details: {
            'items':      order.items.length,
            'new_status': status.name,
            'reason':     'aucun article n\'a pu sortir du stock',
          },
        );
      }
    } else if (decision.action == StockAction.restore) {
      await _restoreOrderStock(order);
    }
    // Persister le flag « stock sorti » s'il change (mouvement OU simple
    // réalignement d'idempotence), pour que les transitions ultérieures et les
    // autres devices décident correctement.
    if (reservedToPersist != reserved) {
      map['stock_reserved'] = reservedToPersist;
      await _ordersBox.put(orderId, map);
      final supa2 = Map<String, dynamic>.from(map)..remove('image_url');
      AppDatabase.bgWriteOrder(supa2);
    }
  }

  /// H4 — une restitution de stock n'a PAS pu être appliquée (produit ou
  /// variante introuvable : supprimé, archivé, ou id changé). On NE l'avale
  /// plus en silence (`continue` muet = fuite invisible) : on trace dans le
  /// journal d'activité (visible par l'owner) pour correction manuelle.
  static void _logRestockMiss(
      Sale order, String productId, int qty, String context) {
    debugPrint('[Stock] ⚠️ restitution IMPOSSIBLE ($context) — produit '
        '$productId qty=$qty commande ${order.id} : STOCK NON RESTITUÉ');
    ActivityLogService.log(
      action:      'stock_restore_failed',
      targetType:  'sale',
      targetId:    order.id,
      targetLabel: order.clientName,
      shopId:      order.shopId,
      details: {
        'context':    context,
        'product_id': productId,
        'quantity':   qty,
      },
    );
  }

  /// Restaure le stock d'une commande qui passe de `completed` à un autre
  /// statut. Route vers la bonne source selon le mode de livraison :
  /// partenaire → StockLevel de la location ; sinon → variante boutique.
  static Future<void> _restoreOrderStock(Sale order) async {
    final products = AppDatabase.getProductsForShop(order.shopId);
    final usePartner = order.deliveryMode == DeliveryMode.partner
        && (order.deliveryLocationId ?? '').isNotEmpty;
    // STK-1 — on ne rend QUE ce qui est réellement sorti. Depuis que le
    // drapeau peut être posé sur un décrément PARTIEL (au moins un article),
    // restituer aveuglément toute la commande recréerait le stock des
    // articles qui n'étaient jamais partis.
    //
    // Map vide = journal inconnu (commande antérieure, ou purgée avant le
    // correctif STK-2) → on retombe sur le comportement historique, tout
    // restituer. Le repli est automatique, sans drapeau de version.
    final stillOut = _stillOutByVariant(order.id);
    final selective = stillOut.isNotEmpty;
    for (final item in order.items) {
      final (pid, vid) = _resolveProductVariant(products, item.productId);
      if (pid == null) {
        _logRestockMiss(order, item.productId, item.quantity,
            'restauration commande');
        continue;
      }
      // Symétrie OBLIGATOIRE avec `_decrementOrderStock` : un article dont
      // la vente n'a rien décrémenté ne doit rien recréditer à l'annulation,
      // sinon chaque cycle vente→annulation créerait du stock ex nihilo.
      if (!_isStockTracked(products, pid)) continue;
      var qty = item.quantity;
      if (selective) {
        final out = stillOut[vid] ?? 0;
        if (out <= 0) {
          // Jamais sorti (ou déjà restitué) — on ne rend rien, et on le dit :
          // l'écart entre ce qui est facturé et ce qui revient en stock doit
          // rester lisible dans le journal d'activité.
          _logRestockMiss(order, item.productId, item.quantity,
              'article jamais sorti du stock — aucune restitution');
          continue;
        }
        if (out < qty) qty = out;
        stillOut[vid] = out - qty;
      }
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
        );
      }
    }
  }

  /// Une sortie de stock (vente) n'a PAS pu être appliquée. On NE l'avale
  /// JAMAIS en silence (`continue` muet = perte de stock invisible) : on trace
  /// dans le journal d'activité (visible par l'owner) pour correction et
  /// diagnostic. Miroir de [_logRestockMiss] côté vente.
  static void _logStockDecrementMiss(
      Sale order, SaleItem item, String context) {
    debugPrint('[Stock] ⚠️ DÉCRÉMENT IMPOSSIBLE ($context) — item '
        '${item.productId} "${item.productName}" qty=${item.quantity} '
        'commande ${order.id} : STOCK NON MIS À JOUR');
    ActivityLogService.log(
      action:      'stock_decrement_failed',
      targetType:  'sale',
      targetId:    order.id,
      targetLabel: order.clientName ?? item.productName,
      shopId:      order.shopId,
      details: {
        'context':      context,
        'item_id':      item.productId,
        'product_name': item.productName,
        'quantity':     item.quantity,
      },
    );
  }

  /// Décrémente le stock d'une commande qui passe à `completed`. Route vers
  /// partenaire ou boutique selon le mode de livraison. Chaque article est
  /// isolé (try/catch) : l'échec d'un article ne bloque pas les autres et
  /// n'est JAMAIS silencieux.
  /// Renvoie les variantes dont le stock est RÉELLEMENT sorti.
  ///
  /// STK-1 — ce retour est le cœur du correctif. Le drapeau `stock_reserved`
  /// était posé d'après `StockEngagement.decide()`, une décision PURE qui
  /// ignore tout du résultat : une commande dont aucun article n'avait pu
  /// sortir était quand même marquée « stock engagé ». Une annulation
  /// ultérieure restituait alors du stock jamais pris — elle en CRÉAIT.
  static Future<Set<String>> _decrementOrderStock(Sale order) async {
    final products = AppDatabase.getProductsForShop(order.shopId);
    final usePartner = order.deliveryMode == DeliveryMode.partner
        && (order.deliveryLocationId ?? '').isNotEmpty;
    final moved = <String>{};
    for (final item in order.items) {
      final (pid, vid) = _resolveProductVariant(products, item.productId);
      if (pid == null) {
        _logStockDecrementMiss(
            order, item, 'produit/variante introuvable (vente)');
        continue;
      }
      // Article non suivi en stock (hotfix_138) : sortie SILENCIEUSE et
      // volontaire — contrairement au cas `pid == null`, ce n'est pas une
      // anomalie à tracer mais un choix de configuration du produit.
      if (!_isStockTracked(products, pid)) continue;
      try {
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
        // Sortie CONFIRMÉE : aucune exception n'a été levée.
        moved.add(vid);
      } catch (e) {
        // Stock insuffisant, variante disparue, erreur d'écriture… — tracé,
        // jamais avalé, et sans interrompre les autres articles.
        _logStockDecrementMiss(order, item, 'échec décrément vente : $e');
      }
    }
    return moved;
  }

  /// Référence de commande d'un mouvement de stock, quelle que soit la clé
  /// sous laquelle elle a été écrite.
  ///
  /// `StockService._log` écrivait `reference_id` — une clé qui n'existe PAS
  /// dans la table, dont la colonne s'appelle `reference` depuis l'origine
  /// (hotfix_010). Le client écrit désormais le bon nom, mais les lignes déjà
  /// présentes dans Hive portent l'ancienne clé, et celles qui reviennent du
  /// serveur portent la nouvelle : les deux cohabiteront durablement.
  ///
  /// Ne lire que la nouvelle rendrait l'anti-doublon de retour inopérant et
  /// ferait retomber la restitution sélective (STK-1) sur « tout restituer »
  /// pour tout l'historique local. On lit donc les deux, sans date de
  /// péremption — le coût est nul, l'oubli serait silencieux.
  static String? _movementRef(Map<String, dynamic> m) =>
      (m['reference'] ?? m['reference_id'])?.toString();

  /// Quantité encore SORTIE par variante pour cette commande, d'après le
  /// journal des mouvements.
  ///
  /// Les ventes y sont écrites en quantité négative, les restitutions en
  /// positif, sous le même `type: 'sale'` — on somme donc le net, et on ne
  /// garde que ce qui reste effectivement dehors.
  ///
  /// Map VIDE = aucun mouvement connu pour cette commande : soit elle est
  /// antérieure au correctif, soit son journal a été purgé (cf. STK-2). Dans
  /// ce cas l'appelant retombe sur le comportement historique — tout
  /// restituer — plutôt que de ne rien rendre : mieux vaut l'imprécision
  /// d'hier qu'une perte de stock nouvelle.
  static Map<String, int> _stillOutByVariant(String? orderId) {
    final out = <String, int>{};
    if (orderId == null || orderId.isEmpty) return out;
    if (!Hive.isBoxOpen(HiveBoxes.stockMovements)) return out;
    for (final raw in HiveBoxes.stockMovementsBox.values) {
      try {
        final m = Map<String, dynamic>.from(raw);
        if (_movementRef(m) != orderId) continue;
        if ((m['type'] as String? ?? '') != 'sale') continue;
        final vid = m['variant_id'] as String?;
        if (vid == null || vid.isEmpty) continue;
        final q = (m['quantity'] as num?)?.toInt() ?? 0;
        // Sortie (q < 0) → ce qui est dehors augmente ; restitution (q > 0)
        // → il diminue. D'où le signe inversé.
        out[vid] = (out[vid] ?? 0) - q;
      } catch (_) {/* ligne corrompue — ignorée */}
    }
    out.removeWhere((_, v) => v <= 0);
    return out;
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
  /// [cause] porte le CODE structuré du motif de refus (prix / qualité /
  /// différent / autre) ; [reason] le texte lisible. Les deux atterrissent
  /// dans la même ligne de `stock_movements`, seul réceptacle qui soit
  /// nativement PAR ARTICLE et PAR QUANTITÉ retournée — donc le seul à couvrir
  /// aussi bien le refus total que le refus partiel.
  static Future<void> _approvalReturnStock(
      Sale order, String pid, String vid, int qty, String reason,
      {String? cause}) async {
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
        // `reason` n'était PAS transmis ici — écart ancien, et pas anodin :
        // une tournée « à choisir » part presque toujours d'un emplacement
        // partenaire, si bien que la branche muette était la branche
        // NOMINALE. Tout motif saisi se serait perdu là.
        reason:     reason,
        cause:      cause,
      );
    } else {
      await StockService.reverseSale(
        shopId:    order.shopId,
        productId: pid,
        variantId: vid,
        quantity:  qty,
        orderId:   order.id,
        reason:    reason,
        cause:     cause,
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
        if (pid == null) {
          _logRestockMiss(order, item.productId, item.quantity,
              'rollback réservation à choisir');
          continue;
        }
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
  ///
  /// [amountPaid] = montant TOTAL encaissé du client (cumulé, acompte inclus)
  /// sur la vente finale, saisi au sheet de clôture. Il pilote `amount_paid` +
  /// `payment_status` exactement comme `amountPaidOnComplete` le fait dans
  /// [updateOrderStatus] : sans lui la commande partait en `completed` avec
  /// `amount_paid = 0` / `unpaid` (bug « terminée mais jamais payée »), car la
  /// clôture court-circuite volontairement `updateOrderStatus` (garde-fou
  /// stock). `null` → comportement historique : clôture = entièrement payée.
  /// [refusals] : motif de refus par article — `code` structuré, `detail`
  /// libre. Renseigné pour toute ligne dont une quantité revient, refus total
  /// ou partiel.
  ///
  /// [collectedBy] arrive en `String` et non sous son type d'origine :
  /// `CollectedBy` vit dans la couche PRÉSENTATION, et la couche données ne
  /// doit pas l'importer. On transporte sa valeur, pas son type.
  Future<void> closeApprovalOrder(
      String orderId, Map<String, int> keptByItemId,
      {double? amountPaid,
       String? collectedBy,
       Map<String, ({String code, String? detail})> refusals =
           const {}}) async {
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
      if (pid == null) {
        _logRestockMiss(order, entry.key, entry.value, 'retour clôture à choisir');
        continue;
      }
      // Le motif saisi remplace le libellé générique : c'est cette ligne de
      // `stock_movements` qui portera, durablement, la raison du refus.
      final r = refusals[entry.key];
      await _approvalReturnStock(
          order, pid, vid, entry.value,
          r == null
              ? 'retour vente à choisir'
              : (r.detail == null
                  ? 'retour vente à choisir — ${r.code}'
                  : 'retour vente à choisir — ${r.code} : ${r.detail}'),
          cause: r?.code);
    }

    // 2. Vente finale = articles gardés (qty = quantité gardée).
    final keptItems = <SaleItem>[];
    for (final item in order.items) {
      final k = recon.kept[item.productId] ?? 0;
      if (k > 0) keptItems.add(item.copyWith(quantity: k));
    }

    // 3. Persister.
    final Sale closed;
    if (keptItems.isEmpty) {
      // REFUS TOTAL — la commande ne porte plus aucun article.
      //
      // La marchandise est INTÉGRALEMENT revenue en stock (boucle ci-dessus).
      // Conserver les lignes ferait peser la valeur complète de la commande
      // dans les « Pertes » du tableau de bord, alors que rien n'est perdu :
      // seul le déplacement a coûté. La perte retombe donc sur ce qui a
      // réellement été engagé — livraison + frais annexes.
      //
      // La remise part AVEC les articles, et ce n'est pas cosmétique :
      // `taxAmount` est un getter dérivé, `(subtotal - discountAmount) *
      // taxRate / 100`. Avec un panier vide mais une remise conservée, la
      // TVA deviendrait NÉGATIVE et contaminerait le total. Les deux champs
      // ne peuvent pas être dissociés.
      closed = order.copyWith(
        status:        SaleStatus.cancelled,
        stockReserved: false, // tout a été remis en stock
        items:         const [],
        discountAmount: 0,
        cancellationReason: 'aucun article gardé sur place',
      );
    } else {
      final base = order.copyWith(
        items: keptItems,
        status: SaleStatus.completed,
        // H2 — le réservé est consommé (gardé = vendu définitif, retours
        // déjà recrédités ci-dessus). On éteint le flag : sinon une
        // suppression/annulation ultérieure verrait stock_reserved=true
        // et recréditerait du stock déjà vendu (double-crédit).
        stockReserved: false,
      );
      // Encaissement : le total de la vente finale ne porte QUE les articles
      // gardés (+ livraison + frais), il est donc recalculé ici et non repris
      // du montant réservé.
      final total = base.total;
      final paid  = (amountPaid ?? total).clamp(0, total).toDouble();
      closed = base.copyWith(
        amountPaid:    paid,
        paymentStatus: PaymentStatusX.fromAmount(paid, total),
      );
    }
    await updateOrder(closed);
    // JOURNAL — tenu ICI, et non chez l'appelant.
    //
    // Il y vivait, si bien qu'une clôture déclenchée par un autre chemin
    // n'aurait rien laissé. Le journal suit désormais la donnée : il est écrit
    // là où la commande change réellement d'état, et il porte enfin le DÉTAIL
    // des refus — sans lui, l'écart entre ce qui partait et ce qui revient
    // n'était lisible nulle part.
    ActivityLogService.log(
      action:      'approval_closed',
      targetType:  'order',
      targetId:    orderId,
      targetLabel: order.clientName ?? 'Commande',
      shopId:      order.shopId,
      details: {
        'kept_total':     recon.totalKept,
        'returned_total': recon.totalReturned,
        'final_status':   closed.status.name,
        'amount_paid':    amountPaid,
        if (collectedBy != null) 'collected_by': collectedBy,
        if (refusals.isNotEmpty)
          'refusals': [
            for (final e in refusals.entries)
              {
                'product_id': e.key,
                'code':       e.value.code,
                if (e.value.detail != null) 'detail': e.value.detail,
              },
          ],
      },
    );
    // La commande est finalisée (completed ou cancelled) : plus aucun rappel
    // de livraison à faire sonner. `updateOrderStatus` le fait pour les
    // transitions génériques ; la clôture ne passant pas par lui, on le fait
    // ici (sinon notification fantôme sur une tournée déjà close).
    await DeliveryReminderService.cancelFor(orderId);
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
        if (pid == null) {
          _logRestockMiss(order, item.productId, item.quantity,
              'annulation vente à choisir');
          continue;
        }
        await _approvalReturnStock(
            order, pid, vid, item.quantity,
            reason ?? 'annulation vente à choisir');
      }
    }
    // Même traitement que le refus total dans `closeApprovalOrder` : la
    // marchandise est revenue en stock (boucle ci-dessus), la commande ne
    // porte donc plus d'articles et la perte se limite à ce qui a été engagé
    // — livraison + frais annexes.
    //
    // Sans cet alignement, le MÊME évènement métier — une tournée entièrement
    // refusée — pèserait deux montants différents dans les « Pertes » selon
    // le bouton pressé : valeur pleine par ici, livraison seule par la
    // clôture. La remise part avec les articles, faute de quoi `taxAmount`,
    // qui dérive de `(subtotal - discountAmount)`, deviendrait négatif.
    final cancelled = order.copyWith(
      status:             SaleStatus.cancelled,
      stockReserved:      false,
      items:              const [],
      discountAmount:     0,
      cancellationReason: reason,
    );
    await updateOrder(cancelled);
    // Journal tenu ici plutôt que chez l'appelant — même raison que pour la
    // clôture : l'évènement appartient à la donnée, pas à l'écran qui l'a
    // déclenché.
    ActivityLogService.log(
      action:      'approval_cancelled',
      targetType:  'order',
      targetId:    orderId,
      targetLabel: order.clientName ?? 'Commande',
      shopId:      order.shopId,
      details: {
        'items':          order.items.length,
        'stock_restored': order.stockReserved,
        if (reason != null) 'reason': reason,
      },
    );
    await DeliveryReminderService.cancelFor(orderId);
  }

  /// True si le produit [pid] est suivi en stock (hotfix_138).
  ///
  /// `track_stock = false` marque un article produit à la demande (plat
  /// cuisiné, service, prestation) : il n'a pas de stock à décrémenter ni à
  /// restituer. Sans ce filtre, chaque vente d'un tel article dégradait un
  /// stock qui n'a pas de sens, ou polluait le journal d'activité d'une
  /// entrée `stock_decrement_failed` par ligne vendue.
  ///
  /// Produit introuvable → `true` (comportement historique) : l'absence de
  /// produit est déjà tracée par les `_log*Miss` appelants, ce n'est pas à
  /// cette fonction de la masquer.
  static bool _isStockTracked(List<dynamic> products, String pid) {
    for (final p in products) {
      if (p.id == pid) return p.trackStock as bool;
    }
    return true;
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

    // Restitution du stock AVANT marquage supprimé — garde-fou intégrité.
    // Idempotence : si la commande est DÉJÀ supprimée, on ne rejoue PAS la
    // restitution (sinon double-crédit de stock). Seuls le marquage Hive et
    // la RPC, eux idempotents, se réappliquent.
    final alreadyDeleted = map['deleted_at'] != null;
    if (!alreadyDeleted) {
      final order = _mapToSaleWithStatus(map);
      if (order.isApprovalSale && order.stockReserved) {
        // Vente « à choisir sur place » encore réservée : le stock a été
        // SORTI du disponible à la réservation (reserveApprovalOrder). La
        // supprimer sans le remettre = perte sèche. On restitue TOUS les
        // articles portés, puis on éteint le flag réservé pour rester
        // idempotent (comme cancelApprovalOrder).
        final products = AppDatabase.getProductsForShop(order.shopId);
        for (final item in order.items) {
          final (pid, vid) = _resolveProductVariant(products, item.productId);
          if (pid == null) {
            _logRestockMiss(order, item.productId, item.quantity,
                'suppression vente à choisir');
            continue;
          }
          await _approvalReturnStock(
              order, pid, vid, item.quantity, 'suppression vente à choisir');
        }
        map['stock_reserved'] = false;
      } else if (!order.isApprovalSale &&
          (map['status'] as String?) == 'completed') {
        // Defensive : commande `completed` standard (ne devrait pas arriver
        // — le use case bloque en amont — mais protège rejeux / legacy mal
        // sourcés). Les ventes à choisir gèrent leur stock ci-dessus.
        // NB : `processing` (En cours) est désormais NON supprimable
        // (DeleteSaleUseCase.allowedStatuses) → pas de restitution ici.
        await _restoreOrderStock(order);
      }
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
    'discount_reason': sale.discountReason,
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
    'modifiers':    i.modifiers,
  };

  /// Normalise les options de menu d'une ligne (module restaurant).
  ///
  /// La valeur arrive soit en `List<Map>` (Hive), soit en `List<dynamic>`
  /// issue du JSONB Supabase, soit absente (toute commande non-restaurant,
  /// et toutes les commandes antérieures à hotfix_137) → liste vide.
  static List<Map<String, dynamic>> _modifiersFromRaw(dynamic raw) {
    if (raw is! List) return const [];
    final out = <Map<String, dynamic>>[];
    for (final e in raw) {
      if (e is Map) out.add(Map<String, dynamic>.from(e));
    }
    return out;
  }

  /// GF-5 — Anti-doublon retour. Retourne `true` si au moins un mouvement
  /// `return_client_good` ou `return_defective` existe avec
  /// `reference = orderId` dans `stock_movements` — l'ancienne clé
  /// `reference_id` restant lue par [_movementRef] pour l'historique local.
  /// Si [variantId] est
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
        if (_movementRef(m) != orderId) continue;
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
        if (_movementRef(m) != orderId) continue;
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
            modifiers:   _modifiersFromRaw(map['modifiers']),
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
      discountReason: m['discount_reason'] as String?,
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
      deliveryQuartier: m['delivery_quartier'] as String?,
      deliveryZone:     m['delivery_zone']     as String?,
      deliveryPrice:   (m['delivery_price'] as num?)?.toDouble(),
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
      // Jeton de suivi (hotfix_171) — lecture seule, jamais écrit par le client.
      trackingToken:      m['tracking_token'] as String?,
      // Vente « à choisir sur place » (lecture tolérante : colonnes absentes
      // sur les commandes legacy → false).
      isApprovalSale:     (m['is_approval_sale'] as bool?) ?? false,
      stockReserved:      (m['stock_reserved'] as bool?) ?? false,
      // Module restaurant (hotfix_137). Lu ICI et non dans
      // `_mapToSaleWithStatus` : ce dernier passe par `copyWith`, qui résout
      // les nullables par `??` — une valeur null en base y serait ignorée
      // et la commande garderait la table de `base`.
      tableId:            m['table_id'] as String?,
      tabLabel:           m['tab_label'] as String?,
      // `covers` transite en `num` via le JSON Supabase : un cast direct
      // `as int?` lèverait sur un retour double.
      covers:             (m['covers'] as num?)?.toInt(),
      orderType:          (m['order_type'] as String?) ?? 'takeaway',
      sentToKitchen:      (m['sent_to_kitchen'] as bool?) ?? false,
      kitchenReady:       (m['kitchen_ready'] as bool?) ?? false,
      served:             (m['served'] as bool?) ?? false,
      finished:           (m['finished'] as bool?) ?? false,
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