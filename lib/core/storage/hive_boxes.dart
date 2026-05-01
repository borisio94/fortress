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

  static Future<void> init() async {
    final appDir = await getApplicationSupportDirectory();
    await Hive.initFlutter(appDir.path);

    // Fermer toutes les boxes avant réouverture (protection double init)
    for (final name in _allBoxes) {
      await _safeClose(name);
    }

    // Ouvrir toutes les boxes
    await Hive.openBox(cart);
    await Hive.openBox(settings);
    await Hive.openBox<Map>(offlineQueue);
    await Hive.openBox<Map>(shops);
    await Hive.openBox<Map>(users);
    await Hive.openBox<Map>(memberships);
    await Hive.openBox<Map>(products);
    await Hive.openBox<Map>(sales);
    await Hive.openBox<Map>(clients);
    await Hive.openBox<Map>(orders);
    await Hive.openBox<Map>(suppliers);
    await Hive.openBox<Map>(receptions);
    await Hive.openBox<Map>(incidents);
    await Hive.openBox<Map>(stockMovements);
    await Hive.openBox<Map>(purchaseOrders);
    await Hive.openBox<Map>(stockArrivals);
    await Hive.openBox<Map>(activityLogs);
    await Hive.openBox<Map>(expenses);
    await Hive.openBox<Map>(stockLocations);
    await Hive.openBox<Map>(stockLevels);
    await Hive.openBox<Map>(stockTransfers);
  }

  static const _allBoxes = [
    cart, settings, offlineQueue,
    shops, users, memberships, products, sales, clients, orders,
    suppliers, receptions, incidents, stockMovements, purchaseOrders, stockArrivals,
    activityLogs, expenses,
    stockLocations, stockLevels, stockTransfers,
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
  static Box<Map>   get stockLocationsBox => Hive.box<Map>(stockLocations);
  static Box<Map>   get stockLevelsBox    => Hive.box<Map>(stockLevels);
  static Box<Map>   get stockTransfersBox => Hive.box<Map>(stockTransfers);
}