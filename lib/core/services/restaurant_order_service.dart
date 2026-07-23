import 'package:flutter/foundation.dart' show debugPrint;

import '../../features/caisse/data/repositories/sale_local_datasource.dart';
import '../../features/caisse/domain/entities/sale.dart';
import '../../features/caisse/domain/entities/sale_item.dart';
import '../../features/restaurant/domain/entities/menu_modifier.dart';
import '../../features/restaurant/domain/entities/restaurant_table.dart';
import '../database/app_database.dart';
import '../storage/hive_boxes.dart';
import 'restaurant_table_service.dart';

/// Opérations de commande propres au service en salle.
///
/// Volontairement séparé de `CaisseBloc` : le flux restaurant a sa propre
/// UI et son propre cycle de vie (ouvrir une table → envoyer en cuisine →
/// servir → encaisser). Seule la COUCHE DONNÉES est mutualisée — les
/// commandes restaurant sont des lignes `orders` comme les autres, ce qui
/// leur fait bénéficier gratuitement de la sync, des exports et des factures.
class RestaurantOrderService {
  RestaurantOrderService._();

  static final SaleLocalDatasource _ds = SaleLocalDatasource();

  /// Prix final d'une ligne, options comprises.
  ///
  /// L'impact des options est MATÉRIALISÉ dans `customPrice` au lieu d'être
  /// recalculé à la lecture : une dizaine d'endroits dans l'app recalculent
  /// un total à partir de `custom_price ?? unit_price` (dashboard, exports,
  /// métriques client, tracking web…). En matérialisant, tous restent justes
  /// sans connaître l'existence des modificateurs.
  static double priceWithModifiers(
      double basePrice, List<Map<String, dynamic>> modifiers) {
    var total = basePrice;
    for (final m in modifiers) {
      total += ((m['price_impact'] as num?) ?? 0).toDouble();
    }
    // Une option « remise » ne doit jamais rendre la ligne négative.
    return total < 0 ? 0 : total;
  }

  /// Construit une ligne de commande à partir d'un produit et des options
  /// choisies, avec le prix déjà matérialisé.
  static SaleItem buildItem({
    required String productId,
    required String productName,
    required double unitPrice,
    required double priceBuy,
    String? imageUrl,
    String? variantName,
    int quantity = 1,
    List<Map<String, dynamic>> modifiers = const [],
  }) {
    final finalPrice = priceWithModifiers(unitPrice, modifiers);
    return SaleItem(
      productId: productId,
      productName: productName,
      unitPrice: unitPrice,
      // Pas de customPrice quand il n'y a aucune option : on évite de
      // déclencher `isPriceAlertTriggered` et l'affichage « prix modifié »
      // sur une ligne au tarif normal.
      customPrice: modifiers.isEmpty ? null : finalPrice,
      priceBuy: priceBuy,
      quantity: quantity,
      imageUrl: imageUrl,
      variantName: variantName,
      modifiers: modifiers,
    );
  }

  /// Commande en cours d'une table, ou `null` si la table n'en a pas.
  ///
  /// Résout d'abord par `currentOrderId`, puis retombe sur une recherche par
  /// `table_id` : si l'app a été fermée entre la création de la commande et
  /// la mise à jour de la table, le lien serait sinon perdu.
  static Sale? currentOrderFor(RestaurantTable table) {
    final id = table.currentOrderId;
    if (id != null && id.isNotEmpty) {
      final byId = _ds.getOrderById(id);
      if (byId != null && !byId.isDeleted) return byId;
    }
    try {
      final orders = _ds.getOrders(table.shopId);
      for (final o in orders) {
        if (o.tableId != table.id) continue;
        if (o.isDeleted) continue;
        if (o.status == SaleStatus.completed ||
            o.status == SaleStatus.cancelled) {
          continue;
        }
        return o;
      }
    } catch (e) {
      debugPrint('[Restaurant] currentOrderFor err: $e');
    }
    return null;
  }

  /// Crée ou met à jour la commande d'une table.
  ///
  /// Statut `scheduled` : le stock n'est pas décrémenté à la prise de
  /// commande, il le sera à l'encaissement (PR-3) — même sémantique que la
  /// commande e-commerce « Enregistrer », donc aucun risque de perte de stock
  /// si la table est finalement annulée.
  static Future<Sale> saveTableOrder({
    required RestaurantTable table,
    required List<SaleItem> items,
    required int covers,
    Sale? existing,
  }) async {
    final now = DateTime.now();
    if (existing != null) {
      final updated = existing.copyWith(
        items: items,
        covers: covers,
      );
      await _ds.updateOrder(updated);
      return updated;
    }

    final order = Sale(
      id: 'order_${now.millisecondsSinceEpoch}',
      shopId: table.shopId,
      items: items,
      paymentMethod: PaymentMethod.cash,
      status: SaleStatus.scheduled,
      createdAt: now,
      orderType: 'dine_in',
      tableId: table.id,
      covers: covers,
      // Le nom de table sert de libellé client sur la facture et dans les
      // listes de commandes, où un client nommé est attendu.
      clientName: table.name,
    );
    await _ds.saveOrder(order);
    // Lien retour table → commande, pour rouvrir la bonne commande au tap.
    await RestaurantTableService.save(table.copyWith(
      status: RestaurantTableStatus.occupee,
      covers: covers,
      currentOrderId: order.id,
      openedAt: table.openedAt ?? now,
    ));
    return order;
  }

  /// Crée une commande à emporter prise au comptoir.
  ///
  /// Statut `scheduled` : le stock n'est pas décrémenté à la prise mais à
  /// l'encaissement, comme pour le service en salle. `order_type` explicite
  /// pour que la commande apparaisse dans « À emporter » et soit comptée
  /// dans le bon canal du tableau de bord.
  static Future<Sale> createTakeawayOrder({
    required String shopId,
    required List<SaleItem> items,
    String? clientName,
  }) async {
    final now = DateTime.now();
    final order = Sale(
      id: 'order_${now.millisecondsSinceEpoch}',
      shopId: shopId,
      items: items,
      paymentMethod: PaymentMethod.cash,
      status: SaleStatus.scheduled,
      createdAt: now,
      orderType: 'takeaway',
      // Les listes de commandes affichent le nom du client : sans valeur,
      // une commande de comptoir apparaîtrait vide et illisible.
      clientName: (clientName?.trim().isNotEmpty ?? false)
          ? clientName!.trim()
          : 'Comptoir',
    );
    await _ds.saveOrder(order);
    return order;
  }

  /// Envoie le bon en cuisine.
  ///
  /// Update CIBLÉ (`bgUpdateOrder`) et non réécriture complète : cela évite
  /// toute course avec `status` si un autre poste modifie la commande au même
  /// moment. La map Hive est mutée en parallèle pour rester offline-first.
  static Future<void> sendToKitchen(Sale order) =>
      _patchOrder(order, {'sent_to_kitchen': true, 'kitchen_ready': false});

  /// Marque la préparation terminée (bouton « Commande prête — servir »).
  static Future<void> markKitchenReady(Sale order) =>
      _patchOrder(order, {'kitchen_ready': true});

  /// Renvoie un bon en cuisine (correction d'un « prêt » cliqué par erreur).
  static Future<void> reopenKitchen(Sale order) =>
      _patchOrder(order, {'kitchen_ready': false});

  static Future<void> _patchOrder(
      Sale order, Map<String, dynamic> fields) async {
    final id = order.id;
    if (id == null || id.isEmpty) return;
    try {
      final raw = HiveBoxes.ordersBox.get(id);
      if (raw != null) {
        final map = Map<String, dynamic>.from(raw);
        map.addAll(fields);
        await HiveBoxes.ordersBox.put(id, map);
      }
    } catch (e) {
      debugPrint('[Restaurant] _patchOrder Hive err: $e');
    }
    AppDatabase.bgUpdateOrder(id, fields);
    AppDatabase.notifyOrderChange(order.shopId);
  }

  /// Demande l'addition : la table passe en statut `addition`.
  ///
  /// N'écrit rien sur la commande — c'est un état de SERVICE (le client a
  /// demandé l'addition), pas un état de commande. La commande ne bouge
  /// qu'à l'encaissement.
  static Future<RestaurantTable> requestBill(RestaurantTable table) =>
      RestaurantTableService.requestBill(table);

  /// Encaisse la commande et libère la table.
  ///
  /// Délègue la clôture à `updateOrderStatus`, qui centralise déjà tout le
  /// métier sensible (verrou de transitions GF-4, stamp `completed_at`,
  /// décrément de stock, statut de paiement, dette partenaire, rappels).
  /// Réimplémenter cette séquence côté restaurant aurait dupliqué des règles
  /// financières — d'où la réutilisation de la couche données malgré une UI
  /// entièrement distincte.
  ///
  /// [amountPaid] : montant réellement encaissé. Laisser `null` force
  /// « entièrement payé » ; une valeur inférieure au total laisse une
  /// créance client (cas d'un règlement partiel accepté par le gérant).
  ///
  /// Retourne la commande clôturée, relue depuis le stockage.
  static Future<Sale?> settleAndRelease({
    required Sale order,
    required RestaurantTable table,
    double? amountPaid,
  }) async {
    final id = order.id;
    if (id == null || id.isEmpty) return null;

    await _ds.updateOrderStatus(
      id,
      SaleStatus.completed,
      completedAt: DateTime.now(),
      amountPaidOnComplete: amountPaid,
    );

    // Libération APRÈS clôture réussie : si `updateOrderStatus` lève (GF-4,
    // stock insuffisant…), la table doit rester occupée plutôt que d'être
    // rendue disponible alors que l'addition n'est pas réglée.
    await RestaurantTableService.release(table);

    // La commande GARDE son `table_id` : c'est un fait historique utile aux
    // statistiques par table et à la relecture d'une facture. Seule la table
    // oublie la commande (`current_order_id` remis à null par `release`).
    return _ds.getOrderById(id);
  }

  /// Durée du service en cours, base du « temps de repas » de l'addition.
  static Duration? mealDuration(RestaurantTable table, Sale? order) {
    final start = table.openedAt ?? order?.createdAt;
    if (start == null) return null;
    final d = DateTime.now().difference(start);
    // Une horloge d'appareil mal réglée produirait une durée négative :
    // on préfère ne rien afficher plutôt qu'un « -3 h ».
    return d.isNegative ? null : d;
  }

  /// Montant par personne pour un partage en [shares] parts égales.
  ///
  /// Arrondi à l'unité SUPÉRIEURE : avec un arrondi bas, la somme des parts
  /// serait inférieure au total et la caisse ne tomberait jamais juste.
  static double splitAmount(double total, int shares) {
    if (shares <= 1) return total;
    return (total / shares).ceilToDouble();
  }

  /// Commandes à emporter encore ouvertes, de la plus ancienne à la plus
  /// récente (le client qui attend depuis le plus longtemps passe en tête).
  ///
  /// Inclut les commandes du catalogue web (`source = 'web'`) comme celles
  /// prises au comptoir : côté personnel, une commande à emporter se traite
  /// de la même façon quelle que soit son origine.
  static List<Sale> takeawayOrders(String shopId) {
    try {
      final orders = _ds.getOrders(shopId);
      final out = orders
          .where((o) => o.orderType == 'takeaway')
          .where((o) => !o.isDeleted)
          // Une commande remise ou annulée n'a plus rien à faire dans la
          // file d'attente du comptoir.
          .where((o) =>
              o.status != SaleStatus.completed &&
              o.status != SaleStatus.cancelled &&
              o.status != SaleStatus.refused &&
              o.status != SaleStatus.refunded)
          .toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      return out;
    } catch (e) {
      debugPrint('[Restaurant] takeawayOrders err: $e');
      return [];
    }
  }

  /// Remise d'une commande à emporter au client : clôture + encaissement.
  ///
  /// Paiement à la réception (spec §10) → on force « entièrement payé » en
  /// laissant `amountPaidOnComplete` à null. Aucune table à libérer ici,
  /// contrairement à [settleAndRelease].
  static Future<void> collectTakeaway(Sale order) async {
    final id = order.id;
    if (id == null || id.isEmpty) return;
    await _ds.updateOrderStatus(
      id,
      SaleStatus.completed,
      completedAt: DateTime.now(),
    );
  }

  /// Bons de cuisine en cours : envoyés et pas encore prêts.
  ///
  /// Triés du plus ancien au plus récent — la cuisine traite dans l'ordre
  /// d'arrivée, et le ticket le plus urgent doit être en tête.
  static List<Sale> kitchenTickets(String shopId) {
    try {
      final orders = _ds.getOrders(shopId);
      final tickets = orders
          .where((o) => o.isInKitchen && !o.isDeleted)
          .where((o) =>
              o.status != SaleStatus.cancelled &&
              o.status != SaleStatus.refused)
          .toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      return tickets;
    } catch (e) {
      debugPrint('[Restaurant] kitchenTickets err: $e');
      return [];
    }
  }

  /// Groupes de modificateurs applicables à un produit.
  static List<MenuModifier> modifiersFor(String shopId, String productId) {
    try {
      // Dédupliqué PAR NOM : un groupe lié à plusieurs produits est stocké
      // en autant de lignes que de produits (cf. MenuModifierService), et
      // un groupe peut être à la fois global et explicitement lié. Sans
      // cette déduplication, « Cuisson » s'afficherait deux fois dans la
      // feuille de choix.
      //
      // La ligne SPÉCIFIQUE au produit gagne sur la ligne globale : elle
      // porte les options que le gérant a voulues pour ce plat précis.
      final byName = <String, MenuModifier>{};
      for (final raw in HiveBoxes.menuModifiersBox.values) {
        if (raw['shop_id']?.toString() != shopId) continue;
        try {
          final m = MenuModifier.fromMap(Map<String, dynamic>.from(raw));
          if (!m.appliesTo(productId) || m.options.isEmpty) continue;
          final existing = byName[m.name];
          if (existing == null || (existing.productId == null &&
              m.productId != null)) {
            byName[m.name] = m;
          }
        } catch (_) {/* ligne corrompue ignorée */}
      }
      final out = byName.values.toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return out;
    } catch (e) {
      debugPrint('[Restaurant] modifiersFor err: $e');
      return [];
    }
  }
}
