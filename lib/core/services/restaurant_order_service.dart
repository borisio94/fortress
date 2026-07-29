import 'package:flutter/foundation.dart' show debugPrint;

import '../../features/caisse/data/repositories/sale_local_datasource.dart';
import '../../features/caisse/domain/entities/sale.dart';
import '../../features/caisse/domain/entities/sale_item.dart';
import '../../features/restaurant/domain/entities/menu_modifier.dart';
import '../../features/restaurant/domain/entities/restaurant_table.dart';
import '../config/restaurant_mode.dart';
import '../database/app_database.dart';
import '../storage/hive_boxes.dart';
import 'daily_menu_service.dart';
import 'recipe_service.dart';
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

  /// TOUTES les commandes ouvertes d'une table — un compte par commande.
  ///
  /// Une table peut héberger plusieurs comptes simultanés : clients distincts
  /// assis ensemble, ou groupes qui paieront séparément. Le lien réel est
  /// `Sale.tableId` ; `RestaurantTable.currentOrderId`, au singulier, ne peut
  /// en désigner qu'un et reste donc un raccourci d'affichage hérité.
  ///
  /// Triées de la plus ancienne à la plus récente : l'ordre d'arrivée à table
  /// est celui que le service a en tête.
  static List<Sale> openOrdersFor(RestaurantTable table) {
    try {
      final open = <Sale>[];
      for (final o in _ds.getOrders(table.shopId)) {
        if (o.tableId != table.id) continue;
        if (o.isDeleted) continue;
        if (o.status == SaleStatus.completed ||
            o.status == SaleStatus.cancelled) {
          continue;
        }
        open.add(o);
      }
      open.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      return open;
    } catch (e) {
      debugPrint('[Restaurant] openOrdersFor err: $e');
      return const [];
    }
  }

  /// Nombre de comptes ouverts et total cumulé d'une table.
  static ({int count, double total}) tableSummary(RestaurantTable table) {
    final orders = openOrdersFor(table);
    return (
      count: orders.length,
      total: orders.fold<double>(0, (s, o) => s + o.total),
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

  /// Tournée EN ATTENTE d'une table : la commande pas encore envoyée en
  /// cuisine, sur laquelle les nouveaux articles s'ajoutent.
  ///
  /// Une tournée = un envoi = un bon de cuisine. Une fois envoyée, elle est
  /// figée : commander un apéritif pendant la préparation ouvre une NOUVELLE
  /// tournée plutôt que de corriger le bon déjà parti en cuisine.
  ///
  /// [tabLabel] cadre la recherche sur un compte précis — deux clients à la
  /// même table ont chacun leurs tournées.
  static Sale? pendingRoundFor(RestaurantTable table, {String? tabLabel}) {
    final wanted = (tabLabel ?? '').trim();
    for (final o in openOrdersFor(table)) {
      if ((o.tabLabel ?? '').trim() != wanted) continue;
      if (o.sentToKitchen) continue;
      return o;
    }
    return null;
  }

  /// Numéro de la tournée en cours sur un compte (1 pour la première).
  ///
  /// Sert au bon de cuisine : « Tournée 2 » dit au cuisinier qu'il s'agit
  /// d'un ajout et non d'un doublon du bon précédent.
  static int roundNumberFor(RestaurantTable table, {String? tabLabel}) {
    final wanted = (tabLabel ?? '').trim();
    return openOrdersFor(table)
            .where((o) => (o.tabLabel ?? '').trim() == wanted)
            .length +
        1;
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
    String? tabLabel,
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
      tabLabel: tabLabel,
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

  /// Envoie une tournée en cuisine : elle est marquée `sentToKitchen` et donc
  /// FIGÉE. `pendingRoundFor` ne la renverra plus, et les articles suivants
  /// ouvriront une nouvelle tournée — c'est ce qui permet de commander un
  /// apéritif pendant que le plat est en préparation, sans réécrire un bon
  /// déjà imprimé.
  static Future<Sale> sendRound(Sale order) async {
    final sent = order.copyWith(sentToKitchen: true);
    await _ds.updateOrder(sent);
    return sent;
  }

  /// Annule une tournée PAS ENCORE envoyée en cuisine.
  ///
  /// Rien n'a été engagé : aucun ingrédient prélevé, aucun bon imprimé. Il n'y
  /// a donc NI perte à déclarer, NI code gérant à demander — contrairement à
  /// l'annulation d'une tournée déjà partie ([ServiceIncidentService]), où la
  /// matière est perdue.
  ///
  /// Le motif est écrit AVANT le changement de statut : `updateOrderStatus`
  /// relit `cancellation_reason` dans la map et refuse l'annulation s'il est
  /// vide (garde-fou GF-4).
  ///
  /// Libère la table si c'était son dernier compte — sinon elle resterait
  /// « occupée » sans personne assis.
  static Future<void> cancelPendingRound(
    Sale order, {
    required String reason,
  }) async {
    final id = order.id;
    if (id == null || id.isEmpty) return;
    await _patchOrder(order, {'cancellation_reason': reason.trim()});
    await _ds.updateOrderStatus(id, SaleStatus.cancelled);

    final tableId = order.tableId;
    if (tableId == null || tableId.isEmpty) return;
    final table = RestaurantTableService.tableById(tableId);
    if (table != null) await RestaurantTableService.releaseIfEmpty(table);
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

  /// Consomme le stock d'une commande SERVIE : disponibilités du jour +
  /// ingrédients des fiches recettes (Lot B).
  ///
  /// Jusqu'ici ce décrément n'existait QUE sur le chemin de la caisse
  /// (`CaisseBloc`) : une table encaissée depuis l'addition, ou une commande
  /// remise au comptoir, ne retirait aucun ingrédient. Les fiches recettes
  /// étaient donc saisies et chiffrées, mais l'inventaire ne bougeait jamais —
  /// la réconciliation trouvait un écart à chaque service.
  ///
  /// QUAND : à la CLÔTURE (encaissement, remise au comptoir) et à l'annulation
  /// d'une tournée déjà envoyée — les deux seuls moments où la matière est
  /// certainement partie. Une tournée annulée AVANT envoi n'a rien engagé et ne
  /// décrémente rien. Chaque commande passe donc par un état terminal une seule
  /// fois (verrou GF-4), ce qui interdit le double décrément sans avoir à
  /// stocker un drapeau supplémentaire.
  ///
  /// JAMAIS bloquant : la vente est déjà enregistrée, une erreur de
  /// bookkeeping ne doit pas la faire échouer.
  static Future<void> consumeStockFor(
      String shopId, List<SaleItem> items) async {
    try {
      if (!isRestaurantShop(shopId)) return;
      await DailyMenuService.consumeForOrder(shopId, items);
      await RecipeService.consumeForOrder(shopId, items);
    } catch (e) {
      debugPrint('[Restaurant] décrément service err: $e');
    }
  }

  /// Ajoute une ligne de frais à la commande (consigne d'emballages, Lot B).
  ///
  /// Les frais s'AJOUTENT au total facturé (cf. `Sale.total`) : c'est ce qui
  /// fait entrer la caution dans l'encaissement sans dupliquer une mécanique
  /// de facturation. Le suivi des retours, lui, vit dans `bottle_deposits`.
  ///
  /// Retourne la commande à jour — l'appelant travaille souvent sur une copie
  /// mémoire qu'il doit rafraîchir.
  static Future<Sale> addFee(
    Sale order, {
    required String label,
    required double amount,
  }) async {
    final fees = [
      ...order.fees,
      {
        'id': 'fee_${DateTime.now().microsecondsSinceEpoch}',
        'label': label,
        'amount': amount,
      },
    ];
    await _patchOrder(order, {'fees': fees});
    return order.copyWith(fees: fees);
  }

  /// Applique une remise sur l'addition (geste sous PIN gérant — Lot A).
  ///
  /// PLAFONNÉE au sous-total : au-delà, `Sale.total` deviendrait négatif et la
  /// commande produirait un encaissement… négatif, que rien en aval ne sait
  /// interpréter. Une remise supérieure au montant des articles est de toute
  /// façon un geste commercial qui n'existe pas — c'est un remboursement.
  ///
  /// Update CIBLÉ comme les autres transitions de service : une réécriture
  /// complète entrerait en course avec un autre poste sur `status`.
  static Future<void> applyDiscount(Sale order, double amount) async {
    final capped = amount < 0
        ? 0.0
        : (amount > order.subtotal ? order.subtotal : amount);
    await _patchOrder(order, {'discount_amount': capped});
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
    PaymentMethod? method,
  }) async {
    final id = order.id;
    if (id == null || id.isEmpty) return null;

    // Mode de règlement dominant, écrit AVANT la clôture par un update ciblé :
    // `updateOrderStatus` ne touche pas à ce champ, et une réécriture complète
    // de la commande entrerait en course avec lui sur `status`.
    //
    // Le détail (mixte, opérateur, rendu monnaie) vit dans `payments` — cette
    // colonne ne porte qu'une valeur, celle du plus gros règlement.
    if (method != null && method != order.paymentMethod) {
      await _patchOrder(order, {'payment_method': method.name});
    }

    await _ds.updateOrderStatus(
      id,
      SaleStatus.completed,
      completedAt: DateTime.now(),
      amountPaidOnComplete: amountPaid,
    );

    // Le stock suit la clôture, pas l'inverse : si `updateOrderStatus` lève,
    // rien n'a été vendu et rien ne doit sortir de l'inventaire.
    await consumeStockFor(table.shopId, order.items);

    // Libération APRÈS clôture réussie : si `updateOrderStatus` lève (GF-4,
    // stock insuffisant…), la table doit rester occupée plutôt que d'être
    // rendue disponible alors que l'addition n'est pas réglée.
    //
    // Et libération CONDITIONNELLE : une table porte plusieurs comptes
    // (clients distincts assis ensemble). La libérer dès qu'UN seul est réglé
    // faisait disparaître les autres du plan de salle — et `release`, qui
    // détache les commandes restantes, transformait leurs additions en
    // comptes flottants. Le premier client payait, le second devenait
    // invisible pour le serveur.
    final remaining = openOrdersFor(table);
    if (remaining.isEmpty) {
      await RestaurantTableService.release(table);
    } else if (table.currentOrderId == id) {
      // Il reste des comptes : la table NE se libère pas. On efface seulement
      // son pointeur vers l'addition qu'on vient d'encaisser, sinon elle
      // rouvrirait sur une commande déjà payée.
      await RestaurantTableService.save(
          table.copyWith(currentOrderId: null));
    }

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
  /// Paiement à la réception (spec §10) : [amountPaid] laissé à `null` force
  /// « entièrement payé » — c'est le cas nominal du comptoir. Une valeur
  /// inférieure au total laisse une créance, comme en salle.
  ///
  /// [method] écrit le mode de règlement dominant (le détail des règlements
  /// vit dans `payments`). Aucune table à libérer ici, contrairement à
  /// [settleAndRelease].
  static Future<void> collectTakeaway(
    Sale order, {
    double? amountPaid,
    PaymentMethod? method,
  }) async {
    final id = order.id;
    if (id == null || id.isEmpty) return;
    if (method != null && method != order.paymentMethod) {
      await _patchOrder(order, {'payment_method': method.name});
    }
    await _ds.updateOrderStatus(
      id,
      SaleStatus.completed,
      completedAt: DateTime.now(),
      amountPaidOnComplete: amountPaid,
    );
    await consumeStockFor(order.shopId, order.items);
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
