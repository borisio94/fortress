import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import '../../features/caisse/data/repositories/sale_local_datasource.dart';
import '../../features/caisse/domain/entities/sale.dart';
import '../../features/caisse/domain/entities/sale_item.dart';
import '../../features/restaurant/domain/courier_pay.dart';
import '../../features/restaurant/domain/discount_reason.dart';
import '../../features/restaurant/domain/settle_guard.dart';
import '../../features/restaurant/domain/entities/restaurant_table.dart';
import '../config/restaurant_mode.dart';
import '../database/app_database.dart';
import '../storage/hive_boxes.dart';
import 'daily_expense_service.dart';
import 'daily_menu_service.dart';
import 'notification_service.dart';
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

  /// Comptes de la table dont les plats sont PRÊTS mais pas encore apportés.
  ///
  /// C'est le seul état qui mérite d'attirer l'œil sur un plan de salle : la
  /// cuisine a fini et personne n'est encore allé chercher l'assiette.
  static List<Sale> waitingServiceFor(RestaurantTable table) =>
      openOrdersFor(table).where((o) => o.isWaitingService).toList();

  /// Nombre de comptes ouverts et total cumulé d'une table.
  static ({int count, double total}) tableSummary(RestaurantTable table) {
    final orders = openOrdersFor(table);
    return (
      count: orders.length,
      total: orders.fold<double>(0, (s, o) => s + o.total),
    );
  }

  /// TOUT ce qu'une table a servi depuis sa création — commandes clôturées
  /// comprises.
  ///
  /// À ne pas confondre avec [tableSummary], qui ne compte que les comptes
  /// ENCORE ouverts. Celui-ci sert à dire, avant de supprimer une table, ce
  /// qu'elle a représenté : une table libre peut n'avoir jamais servi, ou avoir
  /// porté deux cents additions.
  ///
  /// Les commandes supprimées sont exclues ; les annulées comptent — elles ont
  /// bel et bien eu lieu à cette table.
  static int servedCountFor(RestaurantTable table) {
    try {
      var n = 0;
      for (final o in _ds.getOrders(table.shopId)) {
        if (o.tableId != table.id) continue;
        if (o.isDeleted) continue;
        n++;
      }
      return n;
    } catch (e) {
      debugPrint('[Restaurant] servedCountFor err: $e');
      return 0;
    }
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
    /// Couverts à poser sur LA TABLE. Distinct de [covers], qui reste ceux de
    /// CETTE commande : une table peut héberger plusieurs tablées, et le plan
    /// de salle doit afficher leur somme. `null` → [covers], comportement
    /// d'origine pour une table qu'on ouvre.
    int? tableCovers,
    Sale? existing,
    String? tabLabel,
    String? notes,
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
      notes: (notes?.trim().isNotEmpty ?? false) ? notes!.trim() : null,
    );
    await _ds.saveOrder(order);
    // Lien retour table → commande, pour rouvrir la bonne commande au tap.
    await RestaurantTableService.save(table.copyWith(
      status: RestaurantTableStatus.occupee,
      covers: tableCovers ?? covers,
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

  /// Tournée EN ATTENTE d'un compte À EMPORTER (sans table).
  ///
  /// Équivalent de [pendingRoundFor] pour le comptoir : un compte à emporter n'a
  /// pas de table, il n'est identifié que par son libellé.
  static Sale? pendingTakeawayRound(String shopId, {String? tabLabel}) {
    final wanted = (tabLabel ?? '').trim();
    for (final o in takeawayOrders(shopId)) {
      if ((o.tabLabel ?? '').trim() != wanted) continue;
      if (o.sentToKitchen) continue;
      return o;
    }
    return null;
  }

  /// Crée ou met à jour une commande À EMPORTER prise au comptoir.
  ///
  /// Pendant de [saveTableOrder] pour le comptoir. Même sémantique : statut
  /// `scheduled`, donc le stock n'est décrémenté qu'à la remise au client — une
  /// commande abandonnée avant paiement ne coûte rien.
  static Future<Sale> saveTakeawayOrder({
    required String shopId,
    required List<SaleItem> items,
    Sale? existing,
    String? tabLabel,
    String? clientName,
    /// Facultatif : permet de rappeler le client quand la commande traîne au
    /// comptoir. Aucun client CRM n'est créé pour autant — une commande à
    /// emporter n'a pas à peupler le fichier clients.
    String? clientPhone,
    String? notes,
  }) async {
    if (existing != null) {
      final updated = existing.copyWith(items: items);
      await _ds.updateOrder(updated);
      return updated;
    }
    final now = DateTime.now();
    final label = (tabLabel ?? '').trim();
    final order = Sale(
      id: 'order_${now.millisecondsSinceEpoch}',
      shopId: shopId,
      items: items,
      paymentMethod: PaymentMethod.cash,
      status: SaleStatus.scheduled,
      createdAt: now,
      orderType: 'takeaway',
      tabLabel: label.isEmpty ? null : label,
      // Les listes de commandes affichent un nom de client : sans valeur, une
      // commande de comptoir apparaîtrait vide et illisible. Le libellé du
      // compte fait un meilleur repère que « Comptoir » quand il existe.
      clientName: (clientName?.trim().isNotEmpty ?? false)
          ? clientName!.trim()
          : (label.isEmpty ? 'Comptoir' : label),
      clientPhone: (clientPhone?.trim().isNotEmpty ?? false)
          ? clientPhone!.trim()
          : null,
      notes: (notes?.trim().isNotEmpty ?? false) ? notes!.trim() : null,
    );
    await _ds.saveOrder(order);
    return order;
  }

  /// Commande À LIVRER prise au comptoir.
  ///
  /// Volontairement à l'écart du circuit de livraison e-commerce (quartiers
  /// tarifés, partenaire-livreur, transferts de stock, statut « en cours ») :
  /// ici, livrer c'est une adresse et des frais. `deliveryMode` reste NUL —
  /// le renseigner ferait entrer la commande dans les validations e-commerce,
  /// qui exigeraient une ville puis un partenaire.
  ///
  /// Les frais rejoignent `deliveryPrice`, que `Sale.total` additionne déjà :
  /// pas de ligne de frais séparée, donc pas de risque de double comptage.
  static Future<Sale> saveDeliveryOrder({
    required String shopId,
    required List<SaleItem> items,
    required String clientName,
    String? clientPhone,
    String? address,
    double deliveryFee = 0,

    /// Ce que reçoit le LIVREUR, et qui donne lieu à une dépense.
    ///
    /// Distinct des frais : l'établissement peut en garder une part. Nul pour
    /// un salarié, dont le coût est déjà dans la paie.
    double courierPay = 0,

    /// Ce versement sort-il du TIROIR ?
    ///
    /// C'est lui qui décide si la dépense pèse sur la clôture de caisse :
    /// `DailyExpenseService.cashOut` filtre sur `isCash`, et le service de
    /// clôture le somme déjà. Un règlement Mobile Money sort de la banque.
    bool courierPayIsCash = true,

    /// Livreur retenu, sous la forme « Nom · téléphone ». Exigé par le
    /// formulaire de prise de commande ; le paramètre reste nullable pour les
    /// appels programmatiques et les commandes anciennes.
    String? courier,
    String? tabLabel,
    String? notes,
  }) async {
    final now = DateTime.now();
    final label = (tabLabel ?? '').trim();
    final order = Sale(
      id: 'order_${now.millisecondsSinceEpoch}',
      shopId: shopId,
      items: items,
      paymentMethod: PaymentMethod.cash,
      status: SaleStatus.scheduled,
      createdAt: now,
      orderType: 'delivery',
      tabLabel: label.isEmpty ? null : label,
      clientName: clientName.trim().isEmpty ? 'Livraison' : clientName.trim(),
      clientPhone: (clientPhone?.trim().isNotEmpty ?? false)
          ? clientPhone!.trim()
          : null,
      deliveryAddress:
          (address?.trim().isNotEmpty ?? false) ? address!.trim() : null,
      deliveryPrice: deliveryFee > 0 ? deliveryFee : null,
      deliveryPersonName:
          (courier?.trim().isNotEmpty ?? false) ? courier!.trim() : null,
      notes: (notes?.trim().isNotEmpty ?? false) ? notes!.trim() : null,
    );
    await _ds.saveOrder(order);

    // CE QUE LA COURSE A COÛTÉ, écrit au moment où on le sait.
    //
    // Sans cette ligne, les frais étaient encaissés et le livreur payé sans
    // qu'aucun des deux n'apparaisse : ni charge au bilan, ni sortie à la
    // clôture. Un voisin payé du tiroir devenait un MANQUANT imputé au
    // caissier le soir même — le même défaut que les avances sur salaire, et
    // que les heures supplémentaires payées en liquide.
    //
    // Rattachée à la commande par sa description : `DailyExpense` ne porte pas
    // de lien vers une vente, et en ajouter un aurait imposé une migration
    // pour une information dont le seul usage est d'être LUE dans le journal.
    if (courierPayNeedsExpense(courierPay)) {
      await DailyExpenseService.record(
        shopId: shopId,
        description: 'Livraison — ${order.clientName}'
            '${order.deliveryPersonName == null ? '' : ' · ${order.deliveryPersonName}'}',
        amount: courierPay.round(),
        kind: kCourierExpenseKind,
        isCash: courierPayIsCash,
      );
    }
    return order;
  }

  /// Prochain NUMÉRO DE RETRAIT libre du jour — « R1 », « R2 »…
  ///
  /// Premier numéro RÉELLEMENT libre, pas « nombre de commandes + 1 » : deux
  /// commandes encaissées puis une troisième prise reprendrait « R3 » alors
  /// que R1 et R2 sont retournés au client depuis longtemps. Le repère doit
  /// rester court pour être criable au comptoir.
  ///
  /// Remis à zéro chaque jour : un numéro n'a de sens que le temps du service.
  static String nextPickupNumber(String shopId) {
    final today = DateTime.now();
    final labels = <String>[];
    for (final o in _ds.getOrders(shopId)) {
      if (o.orderType != 'takeaway') continue;
      final d = o.createdAt;
      if (d.year != today.year ||
          d.month != today.month ||
          d.day != today.day) {
        continue;
      }
      labels.add(o.tabLabel ?? '');
    }
    return firstFreePickup(labels);
  }

  /// Part PURE de [nextPickupNumber] — testable sans Hive.
  ///
  /// Comparaison insensible à la casse : un « r3 » tapé à la main ne doit pas
  /// laisser le générateur reproposer « R3 » au client suivant.
  @visibleForTesting
  static String firstFreePickup(Iterable<String> takenLabels) {
    final taken = <String>{
      for (final l in takenLabels) l.trim().toLowerCase(),
    }..remove('');
    // Borne haute, comme pour les libellés de compte : au-delà, on rend
    // quand même un repère plutôt que de boucler sans fin.
    for (var n = 1; n <= 999; n++) {
      if (!taken.contains('r$n')) return 'R$n';
    }
    // Repli HORS de la plage balayée. Un modulo retomberait dans R1–R999,
    // c'est-à-dire sur un numéro déjà crié au comptoir : deux clients avec le
    // même repère, et c'est le plat qui part au mauvais.
    return 'R${DateTime.now().millisecondsSinceEpoch}';
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
  ///
  /// ALERTE LA SALLE au passage. C'est le point de rupture du service : la
  /// cuisine a fini, elle passe à autre chose, et l'assiette attend au passe.
  /// Sans notification, elle n'est découverte qu'au prochain regard d'un
  /// serveur — c'est là que les plats refroidissent.
  ///
  /// `served` est remis à false : un bon renvoyé en cuisine puis redéclaré
  /// prêt doit re-alerter, sinon la seconde préparation partirait dans le
  /// silence.
  static Future<void> markKitchenReady(Sale order) async {
    await _patchOrder(order, {'kitchen_ready': true, 'served': false});
    if (!NotificationService.enabledForCurrentUser.value) return;
    NotificationService.notify(
      kind: NotifKind.kitchenReady,
      title: '🍽 Commande prête',
      message: '${_serviceLabel(order)} — à servir',
      shopId: order.shopId,
      targetId: order.id,
    );
  }

  /// Marque les plats APPORTÉS au client — éteint le signal en salle.
  static Future<void> markServed(Sale order) =>
      _patchOrder(order, {'served': true});

  /// Renvoie un bon en préparation (correction d'un « prêt » cliqué par
  /// erreur). Remet aussi à zéro les étapes suivantes : un bon qui repart au
  /// piano n'est ni servi ni terminé.
  static Future<void> reopenKitchen(Sale order) => _patchOrder(
      order, {'kitchen_ready': false, 'served': false, 'finished': false});

  /// SERVICE TERMINÉ, argent non encaissé.
  ///
  /// Sur place : le client a fini de manger. Au comptoir : il a récupéré sa
  /// commande. En livraison : le livreur l'a remise. Rien à faire de plus côté
  /// service — il ne reste que l'addition.
  ///
  /// Pose `served` au passage : on ne termine pas un repas qui n'a jamais été
  /// apporté. Sans ça, une commande à emporter — qui saute l'étape « servie » —
  /// resterait éternellement « prête » dans les compteurs de salle.
  static Future<void> markFinished(Sale order) =>
      _patchOrder(order, {'served': true, 'finished': true});

  /// Retour en arrière depuis « terminée » : le client se rassoit, redemande.
  static Future<void> reopenService(Sale order) =>
      _patchOrder(order, {'finished': false});

  /// Libère la table d'une commande qu'on vient d'encaisser, SI plus aucun
  /// compte n'y est ouvert.
  ///
  /// Pendant de [settleAndRelease] pour les encaissements qui ne passent pas
  /// par l'addition : « Encaisser & finaliser » depuis la page Commandes
  /// clôturait la vente sans jamais toucher au plan de salle, et la table
  /// restait occupée alors que les clients étaient partis depuis longtemps.
  ///
  /// Silencieux et sans effet hors restauration, sur une commande sans table,
  /// ou tant qu'un autre compte reste ouvert.
  static Future<void> releaseTableAfterPayment(Sale order) async {
    final tableId = order.tableId;
    if (tableId == null || tableId.isEmpty) return;
    final table = RestaurantTableService.tableById(tableId);
    if (table == null || table.isFree) return;
    try {
      await RestaurantTableService.releaseIfEmpty(table);
    } catch (e) {
      debugPrint('[Restaurant] libération table post-paiement err: $e');
    }
  }

  /// « Table 4 » · « À emporter — Awa » · à défaut le libellé du compte.
  /// Sert au message d'alerte : un serveur doit savoir OÙ aller, pas quel
  /// identifiant de commande a changé d'état.
  static String _serviceLabel(Sale order) {
    final tab = (order.tabLabel ?? '').trim();
    final table = order.tableId == null
        ? null
        : RestaurantTableService.tableById(order.tableId!);
    if (table != null) {
      return tab.isEmpty ? 'Table ${table.name}' : 'Table ${table.name} · $tab';
    }
    return tab.isEmpty ? 'À emporter' : 'À emporter · $tab';
  }

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
  /// Rend le BILAN du décrément — voir `DailyConsumeReport`.
  ///
  /// PLUS DE `try/catch` ICI, et c'est une correction. Il y en avait un, qui
  /// journalisait dans un `debugPrint` invisible en production. Il ne servait
  /// à rien : `DailyMenuService.read` et `_write` ont chacun le leur et ne
  /// lèvent jamais, donc `consumeForOrder` non plus. On se protégeait d'une
  /// exception qui n'existe pas, pendant que la vraie perte — le rabot à zéro
  /// et l'écriture refusée — passait par-dessous sans un mot.
  static Future<DailyConsumeReport> consumeStockFor(
      String shopId, List<SaleItem> items) async {
    if (!isRestaurantShop(shopId)) return DailyConsumeReport.clean;
    // Disponibilités du jour seulement. Le stock des ingrédients ne se
    // décrémente plus à la vente : sans quantité par plat, il n'y a rien à
    // retirer (cf. `RecipeService`).
    return DailyMenuService.consumeForOrder(shopId, items);
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
  /// [reason] accompagne le montant et suit son sort : retirer la remise
  /// efface le motif, sinon « geste commercial » resterait collé à une
  /// addition qui ne porte plus rien — voir `discount_reason.dart`.
  ///
  /// Le motif est EXIGÉ par la feuille de remise. Il partait jusqu'au
  /// 22/09/2026 dans `activity_logs` et nulle part ailleurs : un champ imposé
  /// au serveur, invisible sur l'addition comme sur la facture.
  static Future<void> applyDiscount(
      Sale order, double amount, String reason) async {
    final capped = amount < 0
        ? 0.0
        : (amount > order.subtotal ? order.subtotal : amount);
    await _patchOrder(order, {
      'discount_amount': capped,
      'discount_reason': discountReasonFor(amount: capped, reason: reason),
    });
  }

  /// Demande l'addition : la table passe en statut `addition`.
  ///
  /// N'écrit rien sur la commande — c'est un état de SERVICE (le client a
  /// demandé l'addition), pas un état de commande. La commande ne bouge
  /// qu'à l'encaissement.
  static Future<RestaurantTable> requestBill(RestaurantTable table) =>
      RestaurantTableService.requestBill(table);

  /// Refuse une seconde clôture — voir `settle_guard.dart`.
  ///
  /// LIT LE STOCKAGE, pas l'objet reçu. L'appelant travaille sur une copie en
  /// mémoire qui peut dater : c'est précisément le cas qu'on couvre, celui du
  /// second appareil dont Hive n'a pas encore reçu l'encaissement du premier.
  /// Vérifier le statut de la copie ne protégerait que du double-tap.
  static void _refuseIfAlreadySettled(String id) {
    final current = _ds.getOrderById(id);
    if (current != null && isAlreadySettled(current.status)) {
      throw const DejaEncaisseeException();
    }
  }

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
  /// Retourne la commande clôturée ET le bilan du décrément du jour.
  ///
  /// LES DEUX, parce que le second était perdu. Un enregistrement en clair —
  /// un champ de plus sur un objet de retour — oblige l'appelant à le
  /// regarder ; un effet de bord silencieux, non. C'est le compilateur qui
  /// tient la garde, pas la bonne volonté.
  static Future<({Sale? order, DailyConsumeReport stock})> settleAndRelease({
    required Sale order,
    required RestaurantTable table,
    double? amountPaid,
    PaymentMethod? method,
  }) async {
    final id = order.id;
    if (id == null || id.isEmpty) {
      return (order: null, stock: DailyConsumeReport.clean);
    }
    _refuseIfAlreadySettled(id);

    // Mode de règlement dominant + FIN DE SERVICE, écrits AVANT la clôture par
    // un update ciblé : `updateOrderStatus` ne touche pas à ces champs, et une
    // réécriture complète de la commande entrerait en course avec lui sur
    // `status`.
    //
    // Le détail du règlement (opérateur, référence) vit dans `payments` — la
    // colonne `payment_method` ne porte qu'une valeur.
    //
    // POURQUOI FORCER `served` ET `finished` : une commande encaissée est
    // servie et terminée, par définition — on ne fait pas payer un client dont
    // l'assiette n'est pas arrivée. Sans ça, un encaissement direct (sans
    // parcourir « prête → servie → terminée ») laissait ces drapeaux à false,
    // et la commande apparaissait payée mais jamais terminée dans les listes.
    await _patchOrder(order, {
      if (method != null && method != order.paymentMethod)
        'payment_method': method.name,
      'served': true,
      'finished': true,
    });

    await _ds.updateOrderStatus(
      id,
      SaleStatus.completed,
      completedAt: DateTime.now(),
      amountPaidOnComplete: amountPaid,
    );

    // Le stock suit la clôture, pas l'inverse : si `updateOrderStatus` lève,
    // rien n'a été vendu et rien ne doit sortir de l'inventaire.
    final stock = await consumeStockFor(table.shopId, order.items);

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
    return (order: _ds.getOrderById(id), stock: stock);
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
  ///
  /// Rend le bilan du décrément du jour, pour la même raison qu'elle.
  static Future<DailyConsumeReport> collectTakeaway(
    Sale order, {
    double? amountPaid,
    PaymentMethod? method,
  }) async {
    final id = order.id;
    if (id == null || id.isEmpty) return DailyConsumeReport.clean;
    _refuseIfAlreadySettled(id);
    // `served` + `finished` forcés : remettre une commande au client, c'est
    // clore son service. Même raison qu'en salle — cf. [settleAndRelease].
    await _patchOrder(order, {
      if (method != null && method != order.paymentMethod)
        'payment_method': method.name,
      'served': true,
      'finished': true,
    });
    await _ds.updateOrderStatus(
      id,
      SaleStatus.completed,
      completedAt: DateTime.now(),
      amountPaidOnComplete: amountPaid,
    );
    return consumeStockFor(order.shopId, order.items);
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
}
