import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

/// Clés des boxes Hive — persistance locale (offline-first)
class HiveBoxes {
  // Boxes existantes
  static const String cart         = 'cart_box';
  static const String settings     = 'settings_box';
  static const String offlineQueue = 'offline_queue_box';

  // Nouvelles boxes métier
  static const String shops        = 'shops_box';
  static const String users        = 'users_box';
  static const String memberships  = 'memberships_box';
  static const String products     = 'products_box';
  static const String sales        = 'sales_box';
  static const String clients      = 'clients_box';
  static const String orders         = 'orders_box';

  // Cycle de vie produit
  static const String suppliers      = 'suppliers_box';
  static const String receptions     = 'receptions_box';
  static const String incidents      = 'incidents_box';
  static const String stockMovements = 'stock_movements_box';
  static const String purchaseOrders = 'purchase_orders_box';
  static const String stockArrivals  = 'stock_arrivals_box';

  // Multi-location (Phase 1 du stock par emplacement)
  static const String stockLocations = 'stock_locations_box';
  static const String stockLevels    = 'stock_levels_box';
  static const String stockTransfers = 'stock_transfers_box';

  // Journal d'activité (cache offline-first + realtime)
  static const String activityLogs   = 'activity_logs_box';

  // Dépenses opérationnelles (charges hors ventes)
  static const String expenses       = 'expenses_box';

  // Notifications in-app (owner) — capped à 50 entries.
  static const String notifications  = 'notifications_box';

  // Templates de message WhatsApp pour transfert de commande au livreur
  // (cf. hotfix_049). Cache offline-first synchronisé via Realtime.
  static const String deliveryTemplates = 'delivery_templates_box';

  // Transferts de commandes vers livreurs/partenaires (cf. hotfix_049/050).
  // Permet aux pages dashboard / commandes / finances de filtrer par
  // partenaire de livraison sans pull réseau à chaque rendu.
  static const String deliveryTransfers = 'delivery_transfers_box';

  // Messagerie hiérarchique (cf. hotfix_055, phase 4).
  // - shopTickets    : tickets ouverts par les membres de la shop
  // - ticketMessages : messages échangés sur les tickets
  static const String shopTickets    = 'shop_tickets_box';
  static const String ticketMessages = 'ticket_messages_box';

  // Acquittements des alertes commandes programmées (cf. sprint alertes).
  // Clés sous la forme "ack:{orderId}:{level}" → bool true. Persisté local
  // uniquement (par device + utilisateur) : sert juste à éviter de re-jouer
  // l'alerte en boucle après que l'opérateur a "vu". Le statut commande
  // côté serveur reste la source de vérité pour clôturer.
  static const String acknowledgedAlerts = 'acknowledged_alerts_box';

  // Comptes partenaires : mouvements signés (ventes encaissées par le
  // partenaire, frais de livraison dûs, versements). Solde par partenaire
  // = SUM(amount) filtré sur partner_location_id.
  static const String partnerLedger = 'partner_ledger_box';

  // File d'attente persistante des uploads d'images produit (PNG).
  // Sur connexion lente, `Future.microtask` ne survit pas à un refresh /
  // fermeture d'onglet : les bytes en mémoire JS sont perdus et l'image
  // disparaît silencieusement après save. Cette box persiste les bytes
  // PNG jusqu'à confirmation d'upload Supabase. Cap à 50 entries (FIFO
  // drop) pour éviter une saturation IndexedDB sur web (~2 Mo × 50 = 100 Mo).
  static const String pendingImageUploads = 'pending_image_uploads_box';

  static Future<void> init() async {
    debugPrint('[Hive] HBX-A init() entered, kIsWeb=$kIsWeb');
    // Wrap englobant : init() ne doit JAMAIS throw, sinon le `.catchError`
    // dans main.dart logue "Hive init error" et masque le vrai problème.
    try {
      if (kIsWeb) {
        // Sur web, on évite Hive.initFlutter() (qui appelle
        // WidgetsFlutterBinding.ensureInitialized → peut hooker des plugins
        // tiers qui invoquent path_provider). Hive.init('') est synchrone,
        // ne touche pas path_provider, et configure IndexedDB pour Hive web.
        try {
          Hive.init('');
          debugPrint('[Hive] HBX-B Hive.init("") web ok');
        } catch (e) {
          debugPrint('[Hive] HBX-B-ERR Hive.init web failed: $e');
        }
      } else {
        final appDir = await getApplicationSupportDirectory();
        await Hive.initFlutter(appDir.path);
        debugPrint('[Hive] HBX-B native init ok');
      }

      for (final name in _allBoxes) {
        await _safeClose(name);
      }
      debugPrint('[Hive] HBX-C all boxes closed');

      await _safeOpen(cart);
      await _safeOpen(settings);
      await _safeOpenMap(offlineQueue);
      await _safeOpenMap(shops);
      await _safeOpenMap(users);
      await _safeOpenMap(memberships);
      await _safeOpenMap(products);
      await _safeOpenMap(sales);
      await _safeOpenMap(clients);
      await _safeOpenMap(orders);
      await _safeOpenMap(suppliers);
      await _safeOpenMap(receptions);
      await _safeOpenMap(incidents);
      await _safeOpenMap(stockMovements);
      await _safeOpenMap(purchaseOrders);
      await _safeOpenMap(stockArrivals);
      await _safeOpenMap(activityLogs);
      await _safeOpenMap(expenses);
      await _safeOpenMap(notifications);
      await _safeOpenMap(stockLocations);
      await _safeOpenMap(stockLevels);
      await _safeOpenMap(stockTransfers);
      await _safeOpenMap(deliveryTemplates);
      await _safeOpenMap(deliveryTransfers);
      await _safeOpenMap(shopTickets);
      await _safeOpenMap(ticketMessages);
      await _safeOpen(acknowledgedAlerts);
      await _safeOpenMap(partnerLedger);
      await _safeOpenMap(pendingImageUploads);
      debugPrint('[Hive] HBX-D all boxes opened (some may have failed)');
    } catch (e, st) {
      debugPrint('[Hive] HBX-FATAL outer init error: $e');
      debugPrint('[Hive] stack: $st');
      // On ne re-throw PAS : l'app doit pouvoir continuer.
    }
    debugPrint('[Hive] HBX-Z init() exit');
  }

  // Bytes vides = StorageBackendMemory dans Hive → box in-memory portable
  // (web + native), ce qui garantit qu'après init la box est TOUJOURS
  // dans `Hive._boxes` même si IndexedDB / le disque a échoué.
  static final Uint8List _emptyBytes = Uint8List(0);

  static Future<void> _safeOpen(String name) async {
    try {
      await Hive.openBox(name);
      debugPrint('[Hive] +ok openBox($name)');
      return;
    } catch (e) {
      debugPrint('[Hive] -ERR openBox($name) try1: $e');
    }
    // Retry — IndexedDB peut être transitoirement bloqué au boot web.
    try {
      await Hive.openBox(name);
      debugPrint('[Hive] +ok openBox($name) retry');
      return;
    } catch (e) {
      debugPrint('[Hive] -ERR openBox($name) try2: $e');
    }
    // Dernier recours : box in-memory pour éviter "Box not found"
    // au prochain accès. Pas de persistance, mais l'app ne crash pas.
    try {
      await Hive.openBox(name, bytes: _emptyBytes);
      debugPrint('[Hive] +ok openBox($name) IN-MEMORY fallback');
    } catch (e) {
      debugPrint('[Hive] -FATAL openBox($name) in-memory failed: $e');
    }
  }

  static Future<void> _safeOpenMap(String name) async {
    try {
      await Hive.openBox<Map>(name);
      debugPrint('[Hive] +ok openBox<Map>($name)');
      return;
    } catch (e) {
      debugPrint('[Hive] -ERR openBox<Map>($name) try1: $e');
    }
    try {
      await Hive.openBox<Map>(name);
      debugPrint('[Hive] +ok openBox<Map>($name) retry');
      return;
    } catch (e) {
      debugPrint('[Hive] -ERR openBox<Map>($name) try2: $e');
    }
    try {
      await Hive.openBox<Map>(name, bytes: _emptyBytes);
      debugPrint('[Hive] +ok openBox<Map>($name) IN-MEMORY fallback');
    } catch (e) {
      debugPrint('[Hive] -FATAL openBox<Map>($name) in-memory failed: $e');
    }
  }

  static const _allBoxes = [
    cart, settings, offlineQueue,
    shops, users, memberships, products, sales, clients, orders,
    suppliers, receptions, incidents, stockMovements, purchaseOrders, stockArrivals,
    activityLogs, expenses, notifications,
    stockLocations, stockLevels, stockTransfers,
    deliveryTemplates, deliveryTransfers,
    shopTickets, ticketMessages,
    acknowledgedAlerts,
    partnerLedger,
    pendingImageUploads,
  ];

  static Future<void> _safeClose(String boxName) async {
    try {
      if (Hive.isBoxOpen(boxName)) {
        await Hive.box(boxName).close();
      }
    } catch (_) {}
  }

  // ── Accesseurs ─────────────────────────────────────────────────────────────
  static Box        get cartBox        => Hive.box(cart);
  static Box        get settingsBox    => Hive.box(settings);
  static Box<Map>   get offlineQueueBox => Hive.box<Map>(offlineQueue);
  static Box<Map>   get shopsBox       => Hive.box<Map>(shops);
  static Box<Map>   get usersBox       => Hive.box<Map>(users);
  static Box<Map>   get membershipsBox => Hive.box<Map>(memberships);
  static Box<Map>   get productsBox    => Hive.box<Map>(products);
  static Box<Map>   get salesBox       => Hive.box<Map>(sales);
  static Box<Map>   get clientsBox     => Hive.box<Map>(clients);
  static Box<Map>   get ordersBox         => Hive.box<Map>(orders);
  static Box<Map>   get suppliersBox     => Hive.box<Map>(suppliers);
  static Box<Map>   get receptionsBox    => Hive.box<Map>(receptions);
  static Box<Map>   get incidentsBox     => Hive.box<Map>(incidents);
  static Box<Map>   get stockMovementsBox => Hive.box<Map>(stockMovements);
  static Box<Map>   get purchaseOrdersBox => Hive.box<Map>(purchaseOrders);
  static Box<Map>   get stockArrivalsBox  => Hive.box<Map>(stockArrivals);
  static Box<Map>   get activityLogsBox   => Hive.box<Map>(activityLogs);
  static Box<Map>   get expensesBox       => Hive.box<Map>(expenses);
  static Box<Map>   get notificationsBox  => Hive.box<Map>(notifications);
  static Box<Map>   get stockLocationsBox => Hive.box<Map>(stockLocations);
  static Box<Map>   get stockLevelsBox    => Hive.box<Map>(stockLevels);
  static Box<Map>   get stockTransfersBox => Hive.box<Map>(stockTransfers);
  static Box<Map>   get deliveryTemplatesBox => Hive.box<Map>(deliveryTemplates);
  static Box<Map>   get deliveryTransfersBox => Hive.box<Map>(deliveryTransfers);
  static Box<Map>   get shopTicketsBox    => Hive.box<Map>(shopTickets);
  static Box<Map>   get ticketMessagesBox => Hive.box<Map>(ticketMessages);
  static Box        get acknowledgedAlertsBox => Hive.box(acknowledgedAlerts);
  static Box<Map>   get partnerLedgerBox      => Hive.box<Map>(partnerLedger);
  static Box<Map>   get pendingImageUploadsBox =>
      Hive.box<Map>(pendingImageUploads);
}