import 'package:hive_flutter/hive_flutter.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide User;
import '../config/supabase_config.dart';
import '../services/notification_service.dart';
import '../storage/hive_boxes.dart';
import '../storage/local_storage_service.dart';
import '../../features/auth/domain/entities/user.dart';
import '../../features/shop_selector/domain/entities/shop_summary.dart';
import '../../features/inventaire/domain/entities/product.dart';
import '../../features/inventaire/domain/entities/stock_location.dart';
import '../../features/inventaire/domain/entities/stock_level.dart';
import '../../features/inventaire/domain/entities/stock_movement.dart';
import '../../features/inventaire/domain/entities/stock_transfer.dart';
import '../../features/crm/domain/entities/client.dart';
import '../../features/expenses/domain/entities/expense.dart';
import '../../features/caisse/domain/entities/sale.dart' show PaymentMethod;
import '../../features/auth/data/models/user_model.dart';
import '../services/activity_log_service.dart';
import '../services/pending_image_upload_service.dart';

typedef OnDataChanged = void Function(String table, String shopId);

// ─── Résultat d'une invitation ────────────────────────────────────────────────
enum InviteOutcome {
  /// L'utilisateur avait déjà un compte → ajouté directement comme membre.
  addedImmediately,
  /// Nouvel email → invitation enregistrée + magic-link envoyé.
  invitationSent,
}

class InviteResult {
  final InviteOutcome outcome;
  final String        email;
  final String?       invitedName; // renseigné si addedImmediately
  const InviteResult({required this.outcome, required this.email, this.invitedName});
}

class AppDatabase {
  static final AppDatabase _i = AppDatabase._();
  factory AppDatabase() => _i;
  AppDatabase._();

  static SupabaseClient get _db => Supabase.instance.client;
  static String? get _userId => Supabase.instance.client.auth.currentUser?.id;

  StreamSubscription? _connectivitySub;
  bool _syncing  = false;
  bool _isOnline = false;
  final Map<String, RealtimeChannel> _channels  = {};
  final List<OnDataChanged>          _listeners = [];

  /// Anti-écho realtime : timestamp ms de la dernière écriture locale par
  /// productId. Quand un event realtime arrive sur un produit qu'on a écrit
  /// très récemment, c'est presque toujours notre propre upsert qui revient
  /// — Supabase ne garantit pas l'ordre d'arrivée pour des écritures
  /// rapprochées sur la même ligne, donc un snapshot intermédiaire peut
  /// écraser un état local plus à jour. Cas reproduit : vente multi-variantes
  /// (4 variantes × 5, vente var A + var B) → l'event de l'écriture var A
  /// (snapshot var B encore à 5) arrivait après le débit local de var B et
  /// remettait var B à 5 → -1 au lieu de -2.
  final Map<String, int> _recentLocalProductWrites = {};
  static const int _localWriteEchoWindowMs = 10000;

  /// Échos temporels pour les `stock_levels` — même rôle que pour les
  /// produits, mais clé = `lvl.id` (déterministe via `_stockLevelId`).
  ///
  /// Pourquoi : un transfert local fait 2-3 écritures stock_levels via
  /// `saveStockLevel` (débit source + crédit destination, +éventuellement
  /// shop fallback). Le `_bgWrite` Supabase est asynchrone. Si un
  /// `syncStockLevels` ou un `_syncShopStockLevelsFromProduct` arrive
  /// pendant que le bgWrite est en route, il peut récupérer la valeur
  /// remote périmée et écraser la valeur locale toute fraîche → on perd
  /// le décrément du transfert (= « stock reste à l'ancien emplacement »).
  ///
  /// Pour résister à un reload navigateur (web) ou à un cold start mobile,
  /// la map est aussi **persistée dans settingsBox** sous la clé
  /// `_kStockLevelEchoKey`. Au boot, on la recharge ; à chaque
  /// `saveStockLevel`, on la flush. TTL = 1 h (au-delà on accepte que
  /// Supabase soit la source de vérité).
  final Map<String, int> _recentLocalStockLevelWrites = {};

  /// Tombstones persistants des produits supprimés localement mais dont
  /// la propagation Supabase peut ne pas être encore confirmée (DELETE
  /// en queue, RLS rejet, conflit avec un push concurrent d'un autre
  /// device, etc.).
  ///
  /// Sans ça, le scénario suivant ressuscite un produit supprimé :
  ///   1. User supprime P1 sur device A → Hive delete + queue DELETE
  ///   2. Pendant l'envoi, device B push un UPDATE pour P1 (snapshot
  ///      antérieur à la suppression) → Supabase réapparait avec P1
  ///   3. Realtime notifie device A « P1 inséré » → A le réintroduit
  ///      en Hive → user voit P1 ressusciter sans raison
  ///
  /// La présence d'un id dans cette set bloque toute réinsertion locale
  /// par `syncProducts` ou `_onProductChange`. TTL 7 jours (largement
  /// suffisant pour la convergence multi-device).
  static const String _kDeletedProductsKey = '_deleted_products_pending';
  static const int _kDeletedProductsTtlMs = 7 * 24 * 60 * 60 * 1000;
  static const String _kStockLevelEchoKey = '_recent_stock_level_writes';
  static const int _kStockLevelEchoTtlMs = 60 * 60 * 1000;

  static void addListener(OnDataChanged cb)    => _i._listeners.add(cb);
  static void removeListener(OnDataChanged cb) => _i._listeners.remove(cb);
  static void notifyOrderChange(String shopId) => _notify('orders', shopId);
  static void notifyProductChange(String shopId) => _notify('products', shopId);

  /// Notifie tous les listeners pour toutes les tables et tous les shops connus.
  /// À appeler après un reset global ou un clear complet des Hive boxes.
  static void notifyAllChanged() {
    final shopIds = <String>{};
    for (final v in HiveBoxes.productsBox.values) {
      final sid = v['store_id'] as String?;
      if (sid != null) shopIds.add(sid);
    }
    for (final v in HiveBoxes.ordersBox.values) {
      final sid = v['shop_id'] as String?;
      if (sid != null) shopIds.add(sid);
    }
    // Même si les boxes sont vides, notifier avec un shopId "global"
    if (shopIds.isEmpty) shopIds.add('_all');
    for (final sid in shopIds) {
      _notify('products', sid);
      _notify('orders', sid);
    }
  }
  static void _notify(String table, String shopId) {
    for (final l in List.of(_i._listeners)) l(table, shopId);
  }

  /// Notifier manuellement les listeners (ex: après setMain)
  static void notifyListeners(String table, String shopId) =>
      _notify(table, shopId);

  /// Sync les rôles ET les statuts (active/suspended/archived) des
  /// boutiques de l'utilisateur depuis Supabase → Hive.
  /// Retourne uniquement la map shop_id → role pour compat existante.
  /// Le statut est stocké séparément dans `shop_status_$userId` et lu
  /// par [getMembershipStatus] (cf. P0-5 : bloquer un employé suspendu
  /// qui voudrait vendre offline).
  static Future<Map<String, String>> syncMemberships(String userId) async {
    try {
      final rows = await _db
          .from('shop_memberships')
          .select('shop_id, role, status')
          .eq('user_id', userId);
      final roles    = <String, String>{};
      final statuses = <String, String>{};
      for (final r in rows as List) {
        final shopId = r['shop_id'] as String;
        roles[shopId]    = r['role']   as String;
        statuses[shopId] = (r['status'] as String?) ?? 'active';
      }
      await HiveBoxes.settingsBox.put('shop_roles_$userId',  roles);
      await HiveBoxes.settingsBox.put('shop_status_$userId', statuses);
      return roles;
    } catch (e) {
      debugPrint('[DB] syncMemberships error: $e');
      return Map<String, String>.from(
          HiveBoxes.settingsBox.get('shop_roles_$userId') as Map? ?? {});
    }
  }

  /// Lire les rôles depuis Hive (offline)
  static Map<String, String> getMemberships(String userId) =>
      Map<String, String>.from(
          HiveBoxes.settingsBox.get('shop_roles_$userId') as Map? ?? {});

  /// Statut du membership de l'utilisateur dans une boutique
  /// ('active' / 'suspended' / 'archived'). Default 'active' si la map
  /// n'a jamais été synchronisée (compat ancienne installation).
  static String getMembershipStatus(String userId, String shopId) {
    final raw = HiveBoxes.settingsBox.get('shop_status_$userId') as Map?;
    if (raw == null) return 'active';
    return (raw[shopId] as String?) ?? 'active';
  }

  /// Vrai si l'utilisateur peut effectuer des actions dans cette boutique
  /// (statut != suspended/archived). Utilisé pour bloquer la création de
  /// ventes depuis la caisse et autres écritures critiques en offline.
  static bool canActInShop(String userId, String shopId) =>
      getMembershipStatus(userId, shopId) == 'active';

  /// Cache le plan Supabase dans Hive pour accès offline
  static Future<void> _cachePlanToHive(String userId) async {
    try {
      final result = await _db.rpc('get_user_plan',
          params: {'p_user_id': userId});
      if (result != null && (result as List).isNotEmpty) {
        final map = Map<String, dynamic>.from(result[0] as Map);
        await HiveBoxes.settingsBox.put('user_plan_$userId', map);
      }
      // Vérifier aussi is_super_admin
      final profile = await _db
          .from('profiles')
          .select('is_super_admin, prof_status')
          .eq('id', userId)
          .maybeSingle();
      if (profile != null) {
        await HiveBoxes.settingsBox.put('user_profile_$userId', profile);
      }
    } catch (e) {
      debugPrint('[DB] _cachePlanToHive error: $e');
    }
  }

  /// Lire le plan depuis Hive (offline)
  static Map<String, dynamic>? getCachedPlan(String userId) {
    final map = HiveBoxes.settingsBox.get('user_plan_$userId');
    return map != null ? Map<String, dynamic>.from(map as Map) : null;
  }

  /// Lire le profil depuis Hive (offline)
  static Map<String, dynamic>? getCachedProfile(String userId) {
    final map = HiveBoxes.settingsBox.get('user_profile_$userId');
    return map != null ? Map<String, dynamic>.from(map as Map) : null;
  }

  // ══ INIT ══════════════════════════════════════════════════════════

  static Future<void> init() async {
    // Au boot, on évite isOnline() qui ping Supabase : l'utilisateur n'est
    // pas encore authentifié, le ping échoue par RLS/timeout et `_isOnline`
    // resterait à false jusqu'au prochain changement d'interface.
    // L'état d'interface de connectivity_plus suffit pour l'init ;
    // les opérations qui ont besoin d'une vérif réelle appellent isOnline().
    final results = await Connectivity().checkConnectivity();
    _i._isOnline = results.any((r) =>
        r == ConnectivityResult.wifi ||
        r == ConnectivityResult.mobile ||
        r == ConnectivityResult.ethernet);
    _i._listenConnectivity();
    // Purge unique des entrées notifications au format historique
    // (id aléatoire pré-déterministe). Cf. NotificationService.notify
    // qui utilise désormais `kind|targetId|shopId` pour écraser au lieu
    // d'accumuler à chaque relance.
    NotificationService.purgeLegacyEntries();
    // Recharger les marqueurs anti-stale persistants (survivent au reload)
    // et purger ceux trop vieux pour rester pertinents.
    await _bootstrapAntiStaleMarkers();
    // Purge opportuniste des `sync_errors` au démarrage : si la queue
    // est vide et qu'aucune op critique n'est bloquée, les erreurs
    // journalisées sont par définition résolues — pas la peine de
    // garder la bannière "Synchro incomplète" affichée jusqu'à
    // expiration 24 h chez un utilisateur qui ferme/rouvre l'app.
    try {
      if (HiveBoxes.offlineQueueBox.isEmpty && stuckCriticalOpsCount == 0) {
        await clearSyncErrors();
      }
    } catch (_) {/* best effort */}
    // Reprend les uploads d'images PNG en attente (sprint B). Cas typique :
    // l'utilisateur a save un produit en 3G, fermé l'onglet avant la fin
    // de l'upload Supabase. Au prochain boot, on retente automatiquement.
    unawaited(PendingImageUploadService.flush());
    debugPrint('[DB] Init — online: ${_i._isOnline}');
  }

  /// Charge les tombstones de produits supprimés et les échos
  /// stock_levels persistés depuis settingsBox vers la map en mémoire.
  /// Purge les entrées expirées au passage (TTL 7j produits, 1h stock).
  static Future<void> _bootstrapAntiStaleMarkers() async {
    try {
      final box = HiveBoxes.settingsBox;
      final now = DateTime.now().millisecondsSinceEpoch;

      // Stock level echoes : recharger en mémoire (filtre TTL).
      final rawSL = box.get(_kStockLevelEchoKey);
      if (rawSL is Map) {
        for (final e in rawSL.entries) {
          final ts = e.value is num ? (e.value as num).toInt() : 0;
          if (now - ts < _kStockLevelEchoTtlMs) {
            _i._recentLocalStockLevelWrites[e.key.toString()] = ts;
          }
        }
        // Réécrire la version compactée pour la prochaine session.
        await box.put(_kStockLevelEchoKey,
            Map<String, int>.from(_i._recentLocalStockLevelWrites));
      }

      // Tombstones produits : purge des entrées expirées.
      final rawDel = box.get(_kDeletedProductsKey);
      if (rawDel is Map) {
        final m = Map<String, dynamic>.from(rawDel);
        m.removeWhere((_, ts) => ts is! num
            || now - ts.toInt() > _kDeletedProductsTtlMs);
        await box.put(_kDeletedProductsKey, m);
        debugPrint('[DB] Tombstones produits actifs: ${m.length}');
      }
    } catch (e) {
      debugPrint('[DB] _bootstrapAntiStaleMarkers error: $e');
    }
  }

  /// Marque un produit comme supprimé localement. Empêche `syncProducts`
  /// et `_onProductChange` realtime de le ressusciter avant que le DELETE
  /// remote ait propagé. TTL 7j.
  static Future<void> _markProductDeletionPending(String productId) async {
    try {
      final box = HiveBoxes.settingsBox;
      final raw = box.get(_kDeletedProductsKey);
      final m = raw is Map
          ? Map<String, dynamic>.from(raw)
          : <String, dynamic>{};
      m[productId] = DateTime.now().millisecondsSinceEpoch;
      await box.put(_kDeletedProductsKey, m);
    } catch (e) {
      debugPrint('[DB] _markProductDeletionPending error: $e');
    }
  }

  /// Le produit est-il marqué pour suppression en attente de propagation ?
  static bool _isProductDeletionPending(String productId) {
    try {
      final raw = HiveBoxes.settingsBox.get(_kDeletedProductsKey);
      if (raw is! Map) return false;
      final ts = raw[productId];
      if (ts is! num) return false;
      final age = DateTime.now().millisecondsSinceEpoch - ts.toInt();
      return age < _kDeletedProductsTtlMs;
    } catch (_) {
      return false;
    }
  }

  /// Retire le tombstone d'un produit (typiquement après confirmation que
  /// la suppression a propagé via realtime DELETE).
  static Future<void> _clearProductDeletionPending(String productId) async {
    try {
      final box = HiveBoxes.settingsBox;
      final raw = box.get(_kDeletedProductsKey);
      if (raw is! Map) return;
      final m = Map<String, dynamic>.from(raw);
      if (m.remove(productId) != null) {
        await box.put(_kDeletedProductsKey, m);
      }
    } catch (_) {/* best effort */}
  }

  /// Persiste la map des échos stock_levels après chaque écriture.
  /// Coût négligeable (Hive est sync rapide) et évite la perte au reload.
  static Future<void> _persistStockLevelEchoes() async {
    try {
      await HiveBoxes.settingsBox.put(
          _kStockLevelEchoKey,
          Map<String, int>.from(_i._recentLocalStockLevelWrites));
    } catch (_) {/* best effort */}
  }

  void _listenConnectivity() {
    _connectivitySub?.cancel();
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final wasOnline = _isOnline;
      _isOnline = results.any((r) =>
      r == ConnectivityResult.wifi ||
          r == ConnectivityResult.mobile ||
          r == ConnectivityResult.ethernet);

      if (!wasOnline && _isOnline) {
        debugPrint('[DB] ✅ Réseau rétabli');
        _onNetworkRestored();
      } else if (wasOnline && !_isOnline) {
        debugPrint('[DB] ⚠️ Réseau perdu — mode offline');
      }
    });
  }

  /// Appelé automatiquement au retour du réseau.
  /// 1. Envoie les ops en attente (écritures faites offline)
  /// 2. Re-sync les données de chaque boutique abonnée (lecture des changements distants)
  Future<void> _onNetworkRestored() async {
    // 1. Flush les ops en attente
    await flushOfflineQueue();
    // 1bis. Reprend aussi les uploads d'images PNG en attente — si
    // l'utilisateur a save offline avec une image, on l'upload mainte-
    // nant que la connexion est revenue.
    unawaited(PendingImageUploadService.flush());

    // 2. Re-sync toutes les boutiques actuellement abonnées
    // pour récupérer les changements faits sur d'autres appareils pendant l'offline
    for (final shopId in List.of(_channels.keys)) {
      try {
        await syncProducts(shopId);
        await syncMetadata(shopId);
        await syncOrders(shopId);
        await syncClients(shopId);
        await syncActivityLogs(shopId);
        await syncExpenses(shopId);
        await syncSuppliers(shopId);
        await syncIncidents(shopId);
        await syncStockMovements(shopId);
        await syncReceptions(shopId);
        await syncPurchaseOrders(shopId);
        await syncStockArrivals(shopId);
        await syncDeliveryTransfers(shopId);
        await syncPartnerLedger(shopId);
        await syncStockLocations();
        await syncStockLevels(shopId);
        _notify('products',     shopId);
        _notify('clients',      shopId);
        _notify('stock_levels', shopId);
        // Rejoue les alertes stock après resync — les changements survenus
        // pendant l'offline arrivent en bloc via syncProducts (pas via
        // Realtime), donc _emitStockNotification ne s'est pas déclenché.
        scanStockNotifications(shopId);
        debugPrint('[DB] Re-sync après reconnexion: $shopId');
      } catch (e) {
        debugPrint('[DB] Re-sync erreur: $e');
      }
    }
  }

  static void dispose() {
    _i._connectivitySub?.cancel();
    _i._channels.forEach((_, ch) => ch.unsubscribe());
    _i._channels.clear();
  }

  // ══ REALTIME ══════════════════════════════════════════════════════

  static void subscribeToShop(String shopId) {
    if (_i._channels.containsKey(shopId)) return;
    debugPrint('[DB] 📡 Realtime subscribe: $shopId');

    // Pull initial depuis Supabase — les abonnements realtime ne notifient
    // que les changements FUTURS. Sans ce pull, un appareil qui entre dans
    // une boutique ne voit pas les données créées auparavant par un autre
    // appareil tant qu'aucune page déclenchante n'est ouverte.
    // Fire-and-forget : n'attend pas, ne bloque pas l'UI.
    _initialPullForShop(shopId);

    final ch = _db.channel('shop_$shopId')
        .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public', table: 'products',
        filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'store_id', value: shopId),
        callback: (p) => _i._onProductChange(p, shopId))
        .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public', table: 'categories',
        filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'shop_id', value: shopId),
        callback: (_) async {
          await syncMetadata(shopId);
          _notify('categories', shopId);
        })
        .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public', table: 'brands',
        filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'shop_id', value: shopId),
        callback: (_) async {
          await syncMetadata(shopId);
          _notify('brands', shopId);
        })
        .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public', table: 'units',
        filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'shop_id', value: shopId),
        callback: (_) async {
          await syncMetadata(shopId);
          _notify('units', shopId);
        })
        .onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public', table: 'activity_logs',
        filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'shop_id', value: shopId),
        callback: (p) => _i._onActivityLogChange(p, shopId))
        .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public', table: 'expenses',
        filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'shop_id', value: shopId),
        callback: (p) => _i._onExpenseChange(p, shopId))
        .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public', table: 'clients',
        // Note : la table clients utilise `store_id` (pas `shop_id`).
        filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'store_id', value: shopId),
        callback: (p) => _i._onClientChange(p, shopId))
        .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public', table: 'orders',
        filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'shop_id', value: shopId),
        callback: (p) => _i._onOrderChange(p, shopId))
        .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public', table: 'suppliers',
        filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'shop_id', value: shopId),
        callback: (p) => _i._onTablePassthroughChange(
            p, HiveBoxes.suppliersBox, 'suppliers', shopId))
        .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public', table: 'incidents',
        filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'shop_id', value: shopId),
        callback: (p) => _i._onTablePassthroughChange(
            p, HiveBoxes.incidentsBox, 'incidents', shopId))
        .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public', table: 'stock_movements',
        filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'shop_id', value: shopId),
        callback: (p) => _i._onTablePassthroughChange(
            p, HiveBoxes.stockMovementsBox, 'stock_movements', shopId))
        .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public', table: 'receptions',
        filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'shop_id', value: shopId),
        callback: (p) => _i._onTablePassthroughChange(
            p, HiveBoxes.receptionsBox, 'receptions', shopId))
        .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public', table: 'purchase_orders',
        filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'shop_id', value: shopId),
        callback: (p) => _i._onTablePassthroughChange(
            p, HiveBoxes.purchaseOrdersBox, 'purchase_orders', shopId))
        .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public', table: 'stock_arrivals',
        filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'shop_id', value: shopId),
        callback: (p) => _i._onTablePassthroughChange(
            p, HiveBoxes.stockArrivalsBox, 'stock_arrivals', shopId))
        .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public', table: 'partner_ledger_entries',
        filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'shop_id', value: shopId),
        callback: (p) => _i._onTablePassthroughChange(
            p, HiveBoxes.partnerLedgerBox,
            'partner_ledger_entries', shopId))
        // ── Tickets de messagerie (phase 4 + notifs cloche) ────────────
        .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public', table: 'shop_tickets',
        filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'shop_id', value: shopId),
        callback: (p) => _i._onTicketChange(p, shopId))
        .onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public', table: 'shop_ticket_messages',
        // Pas de filtre direct sur shop_id (la table n'a pas ce champ) ;
        // on filtre côté callback via le ticket associé.
        callback: (p) => _i._onTicketMessageChange(p, shopId))
        .subscribe((status, [err]) =>
        debugPrint('[DB] Realtime $shopId: $status${err != null ? " err=$err" : ""}'));

    _i._channels[shopId] = ch;
  }

  static void unsubscribeFromShop(String shopId) {
    _i._channels.remove(shopId)?.unsubscribe();
  }

  /// Pull complet déclenchable depuis l'UI (pull-to-refresh) — variante
  /// publique de `_initialPullForShop`. À utiliser depuis un
  /// `RefreshIndicator.onRefresh`. Awaitable, pour que le spinner
  /// natif disparaisse à la fin.
  static Future<void> pullAllForShop(String shopId) =>
      _initialPullForShop(shopId);

  /// Pull initial de toutes les tables métier pour une boutique.
  /// Appelé au `subscribeToShop` — idempotent, safe à rappeler.
  /// Fire-and-forget : n'attend pas, ne bloque pas l'UI.
  static Future<void> _initialPullForShop(String shopId) async {
    // stock_locations + stock_levels en TÊTE DE FILE : si un sync ultérieur
    // (typiquement syncProducts → migrateShopStocksToLocationsV1) hang sur
    // web, on ne perd pas la sync des niveaux de stock partenaires —
    // requis pour que le filtre « Vue partenaire » affiche les produits
    // transférés depuis un autre appareil.
    try {
      await syncStockLocations();
    } catch (e) { debugPrint('[DB] initial syncStockLocations: $e'); }
    try {
      await syncStockLevels(shopId);
      _notify('stock_levels', shopId);
    } catch (e) { debugPrint('[DB] initial syncStockLevels: $e'); }
    try {
      await syncClients(shopId);
      _notify('clients', shopId);
    } catch (e) { debugPrint('[DB] initial syncClients: $e'); }
    try {
      await syncProducts(shopId);
      _notify('products', shopId);
      // Une fois les produits synchronisés, on rejoue les alertes stock pour
      // les produits déjà bas/épuisés (le Realtime ne notifie que les changements
      // futurs).
      scanStockNotifications(shopId);
    } catch (e) { debugPrint('[DB] initial syncProducts: $e'); }
    try {
      await syncOrders(shopId);
      _notify('orders', shopId);
    } catch (e) { debugPrint('[DB] initial syncOrders: $e'); }
    try {
      await syncExpenses(shopId);
      _notify('expenses', shopId);
    } catch (e) { debugPrint('[DB] initial syncExpenses: $e'); }
    try {
      await syncMetadata(shopId);
    } catch (e) { debugPrint('[DB] initial syncMetadata: $e'); }
    try {
      await syncSuppliers(shopId);
    } catch (e) { debugPrint('[DB] initial syncSuppliers: $e'); }
    try {
      await syncIncidents(shopId);
    } catch (e) { debugPrint('[DB] initial syncIncidents: $e'); }
    try {
      await syncStockMovements(shopId);
    } catch (e) { debugPrint('[DB] initial syncStockMovements: $e'); }
    try {
      await syncReceptions(shopId);
    } catch (e) { debugPrint('[DB] initial syncReceptions: $e'); }
    try {
      await syncPurchaseOrders(shopId);
    } catch (e) { debugPrint('[DB] initial syncPurchaseOrders: $e'); }
    try {
      await syncStockArrivals(shopId);
    } catch (e) { debugPrint('[DB] initial syncStockArrivals: $e'); }
    try {
      await syncDeliveryTransfers(shopId);
    } catch (e) { debugPrint('[DB] initial syncDeliveryTransfers: $e'); }
    try {
      await syncPartnerLedger(shopId);
    } catch (e) { debugPrint('[DB] initial syncPartnerLedger: $e'); }
    try {
      await syncActivityLogs(shopId);
      _notify('activity_logs', shopId);
    } catch (e) { debugPrint('[DB] initial syncActivityLogs: $e'); }
  }

  Future<void> _onProductChange(PostgresChangePayload p, String shopId) async {
    try {
      switch (p.eventType) {
        case PostgresChangeEvent.insert:
        case PostgresChangeEvent.update:
          final prod = _supabaseToProduct(p.newRecord);
          if (prod.id != null) {
            final id = prod.id!;
            // Tombstone : produit supprimé localement, on ignore tout
            // INSERT/UPDATE remote tant que la propagation DELETE n'a
            // pas convergé (TTL 7j). Évite la résurrection silencieuse.
            if (_isProductDeletionPending(id)) {
              debugPrint('[DB] ⏭️ realtime tombstone product=$id');
              break;
            }
            // Anti-stale realtime v2 : check `row_version` (cf. migration
            // 015). Plus fiable que la fenêtre temporelle car insensible
            // au timing d'arrivée des events.
            final remoteVersion =
                (p.newRecord['row_version'] as num?)?.toInt() ?? 0;
            final localRaw = HiveBoxes.productsBox.get(id);
            if (localRaw is Map) {
              final localVersion =
                  (localRaw['_row_version'] as num?)?.toInt() ?? 0;
              if (remoteVersion <= localVersion && remoteVersion > 0) {
                debugPrint('[DB] ⏭️ realtime stale '
                    '(remote v=$remoteVersion <= local v=$localVersion) '
                    'product=$id');
                break;
              }
            }
            // Filet de sécurité conservé : fenêtre 10s pour les écritures
            // tout juste poussées qui n'ont pas encore reçu leur version.
            final recentMs = _recentLocalProductWrites[id];
            if (recentMs != null) {
              final age =
                  DateTime.now().millisecondsSinceEpoch - recentMs;
              if (age < _localWriteEchoWindowMs && remoteVersion == 0) {
                debugPrint('[DB] ⏭️ realtime écho local '
                    '${age}ms (sans version) product=$id');
                break;
              }
            }
            // Cohérent avec saveProduct : invalider le cache AVANT le put
            // sinon une lecture concurrente (boucle de débit) servirait la
            // valeur en cache.
            LocalStorageService.invalidateProductsCache();
            final mapToWrite = _productToMap(prod)
              ..['_row_version'] = remoteVersion;
            await HiveBoxes.productsBox.put(id, mapToWrite);
            // Phase 5 : les écritures realtime n'allaient pas dans le
            // pipeline saveProduct, donc le StockLevel shop ne suivait pas.
            await _syncShopStockLevelsFromProduct(prod);
            _emitStockNotification(prod, shopId);
          }
        case PostgresChangeEvent.delete:
          final id = p.oldRecord['id'] as String?;
          if (id != null) {
            await HiveBoxes.productsBox.delete(id);
            // La suppression a propagé côté Supabase → on peut retirer
            // le tombstone (au-delà, il aurait expiré via TTL de toute
            // façon, mais on libère la map plus tôt).
            await _clearProductDeletionPending(id);
          }
        default: break;
      }
      _notify('products', shopId);
    } catch (e) {
      debugPrint('[DB] Erreur onProductChange: $e');
    }
  }

  /// Parcourt les produits en cache d'une boutique et émet une notif pour
  /// chaque produit en rupture / stock bas. Utile au démarrage et après
  /// reconnexion : sans ce scan, seuls les changements Realtime futurs
  /// déclenchent `_emitStockNotification`. Le dédup 60s côté `NotificationService`
  /// empêche les doublons si le scan est rappelé.
  static void scanStockNotifications(String shopId) {
    if (!NotificationService.enabledForCurrentUser.value) return;
    try {
      final products = getProductsForShop(shopId);
      for (final p in products) {
        _i._emitStockNotification(p, shopId);
      }
    } catch (e) {
      debugPrint('[DB] scanStockNotifications: $e');
    }
  }

  /// `true` si l'utilisateur courant a un rôle admin/owner sur ce shop —
  /// porte d'entrée pour les notifs stock et orders qui ne sont pas
  /// pertinentes pour les vendeurs (rôle 'user').
  bool _isAdminOrOwner(String shopId) {
    final uid = _userId;
    if (uid == null) return false;
    final role = _roleOf(shopId, uid);
    if (role == 'admin' || role == 'owner') return true;
    return LocalStorageService.getShop(shopId)?.ownerId == uid;
  }

  /// Émet une notification stock bas / épuisé selon le stock total et
  /// le seuil d'alerte. Le `NotificationService` dédoublonne sur 60s.
  void _emitStockNotification(Product prod, String shopId) {
    if (!NotificationService.enabledForCurrentUser.value) return;
    if (!_isAdminOrOwner(shopId)) return;
    final stock     = prod.totalStock;
    final threshold = prod.stockMinAlert;
    if (stock <= 0) {
      NotificationService.notify(
        kind:    NotifKind.stockOut,
        title:   '🚫 Stock épuisé',
        message: '${prod.name} · Réapprovisionner',
        shopId:   shopId,
        targetId: prod.id,
      );
    } else if (threshold > 0 && stock <= threshold) {
      NotificationService.notify(
        kind:    NotifKind.stockLow,
        title:   '⚠ Stock bas',
        message: '${prod.name} · Stock : $stock',
        shopId:   shopId,
        targetId: prod.id,
      );
    }
  }

  // ══ CONNECTIVITÉ ══════════════════════════════════════════════════

  static Future<bool> isOnline() async {
    try {
      // connectivity_plus vérifie l'interface réseau (peut donner faux positifs)
      final r = await Connectivity().checkConnectivity();
      final hasInterface = r.any((x) =>
      x == ConnectivityResult.wifi ||
          x == ConnectivityResult.mobile ||
          x == ConnectivityResult.ethernet);
      if (!hasInterface) return false;

      // Vérification réelle : tenter un appel Supabase léger
      // Si ça répond → vraiment online
      await _db.from('shops').select('id').limit(1)
          .timeout(const Duration(seconds: 3));
      return true;
    } catch (_) {
      return false;
    }
  }

  // ══ FILE D'ATTENTE OFFLINE ════════════════════════════════════════

  static Future<void> _enqueue(Map<String, dynamic> op) async {
    await HiveBoxes.offlineQueueBox.add({
      ...op, 'queued_at': DateTime.now().toIso8601String(),
    });
    debugPrint('[DB] 📦 Enqueued: ${op["table"]} ${op["op"]}');
  }

  static Future<void> flushOfflineQueue() async {
    if (_i._syncing || _userId == null) return;
    _i._syncing = true;
    int success = 0, failed = 0, skipped = 0;
    try {
      final box  = HiveBoxes.offlineQueueBox;
      final keys = box.keys.toList();
      if (keys.isEmpty) {
        // Bug "bannière Synchro incomplète à vie" : sans cette purge,
        // d'anciennes `sync_errors` (FK 23503, perm 42501, abandons après
        // 10 retries…) restaient affichées jusqu'à expiration 24 h car
        // le bloc de purge en fin de flush était court-circuité par ce
        // early-return. On purge ici aussi quand la queue est déjà vide
        // au moment du flush — tant qu'aucune op critique n'est bloquée,
        // ces erreurs sont par définition résolues.
        if (stuckCriticalOpsCount == 0) {
          await clearSyncErrors();
        }
        return;
      }
      debugPrint('[DB] 🚀 Flush ${keys.length} ops en attente');

      for (final key in keys) {
        final raw = box.get(key);
        if (raw == null) { await box.delete(key); continue; }

        final op  = Map<String, dynamic>.from(raw);
        final retries = (op['_retries'] as int?) ?? 0;
        final table   = op['table'] as String? ?? '';

        // Tables CRITIQUES : ne JAMAIS abandonner. Une vente perdue = du
        // cash perdu. On les garde indéfiniment dans la queue et on alerte
        // l'utilisateur (badge + son) pour qu'il sache qu'une action manuelle
        // est requise (resync ou contact support).
        const criticalTables = {'orders', 'sales', 'expenses'};
        final isCritical = criticalTables.contains(table);

        // Pour les tables non-critiques : abandon après 10 essais (sinon
        // on garde une queue qui grossit à l'infini sur des erreurs réelles).
        if (!isCritical && retries >= 10) {
          debugPrint('[DB] ⛔ Op non-critique abandonnée après 10 tentatives: '
              '$table');
          await box.delete(key);
          _logSyncError(op, 'Abandoned after 10 retries');
          skipped++;
          continue;
        }

        // Pour les critiques : log persistant à chaque palier de 10 retries
        // pour que la queue ne soit pas vidée silencieusement.
        if (isCritical && retries > 0 && retries % 10 == 0) {
          _logSyncError(op,
              'CRITIQUE — vente bloquée après $retries tentatives. '
              'Vérifier réseau ou contacter support.');
        }

        final ok = await _executeOp(op);
        if (ok) {
          await box.delete(key);
          success++;
        } else {
          // Incrémenter le compteur de tentatives
          op['_retries'] = retries + 1;
          op['_last_retry'] = DateTime.now().toIso8601String();
          await box.put(key, op);
          debugPrint('[DB] ⚠️ Op échouée (tentative ${retries+1}'
              '${isCritical ? "/∞" : "/10"}): $table');
          failed++;
        }
      }
      debugPrint('[DB] ✅ Flush terminé: $success succès, $failed échecs, $skipped abandonnés');
      if (success > 0) notifyAllChanged();

      // Si la queue est entièrement vide et qu'aucune op critique n'est
      // bloquée, on purge les erreurs journalisées : elles sont par
      // définition résolues (l'op a soit été rejouée avec succès, soit
      // abandonnée). Sans ça, la bannière "Synchro incomplète" reste
      // affichée à vie sur d'anciennes erreurs déjà traitées.
      if (HiveBoxes.offlineQueueBox.isEmpty && stuckCriticalOpsCount == 0) {
        await clearSyncErrors();
      }
    } finally {
      _i._syncing = false;
    }
  }

  /// Nombre d'opérations en attente avec leur état
  static Map<String, int> get syncQueueStats {
    try { HiveBoxes.offlineQueueBox; } catch (_) { return {'pending': 0, 'failed': 0}; }
    final box = HiveBoxes.offlineQueueBox;
    int pending = 0, failed = 0;
    for (final key in box.keys) {
      final raw = box.get(key);
      if (raw == null) continue;
      final retries = (raw['_retries'] as int?) ?? 0;
      if (retries > 0) failed++; else pending++;
    }
    return {'pending': pending, 'failed': failed};
  }

  /// Réinitialiser la queue (à utiliser avec précaution — perte de données non sync)
  static Future<void> clearSyncQueue() async {
    await HiveBoxes.offlineQueueBox.clear();
    debugPrint('[DB] 🗑️ Queue sync vidée');
  }

  /// Remettre toutes les ops à 0 tentatives pour les réessayer
  static Future<void> resetQueueRetries() async {
    final box = HiveBoxes.offlineQueueBox;
    for (final key in box.keys.toList()) {
      final raw = box.get(key);
      if (raw == null) continue;
      final op = Map<String, dynamic>.from(raw);
      op.remove('_retries');
      op.remove('_last_retry');
      await box.put(key, op);
    }
    debugPrint('[DB] 🔄 Retries réinitialisés: ${box.length} ops prêtes');
  }

  /// Lire les erreurs de sync journalisées (filtrées : on ignore les
  /// entrées de plus de 24 h pour que la bannière "Synchro incomplète"
  /// finisse par disparaître toute seule, même si l'utilisateur n'ouvre
  /// jamais le sheet pour cliquer "Tout réessayer").
  ///
  /// Si le filtrage retire des entrées, on persiste la liste épurée en
  /// best-effort pour éviter que `sync_errors` grossisse à l'infini
  /// (sinon chaque appel filtre la même cargaison de vieilles entrées
  /// sans jamais les supprimer du stockage).
  static List<Map> getSyncErrors() {
    try {
      final all = List<Map>.from(
          (HiveBoxes.settingsBox.get('sync_errors') as List?) ?? []);
      final cutoff = DateTime.now().subtract(const Duration(hours: 24));
      final kept = all.where((e) {
        final t = e['time'] as String?;
        if (t == null) return true; // sans horodatage : on garde
        try {
          return DateTime.parse(t).isAfter(cutoff);
        } catch (_) { return true; }
      }).toList();
      if (kept.length != all.length) {
        try {
          HiveBoxes.settingsBox.put('sync_errors', kept);
        } catch (_) {/* best effort */}
      }
      return kept;
    } catch (_) { return []; }
  }

  /// Vide la liste des erreurs sync journalisées (purge UI). Utile après
  /// un "Tout réessayer" réussi pour ne pas garder visibles des erreurs
  /// désormais résolues. Les erreurs futures ré-écriront cette liste via
  /// `_logSyncError`.
  static Future<void> clearSyncErrors() async {
    try {
      await HiveBoxes.settingsBox.put('sync_errors', <Map>[]);
    } catch (_) {/* best effort */}
  }

  static Future<bool> _executeOp(Map<String, dynamic> op) async {
    try {
      final table = op['table'] as String;
      final type  = op['op']    as String;
      final data  = Map<String, dynamic>.from(op['data'] as Map);
      // onConflict : nom(s) de la contrainte unique à utiliser pour résoudre
      // les doublons quand la clé primaire n'est pas la bonne cible (ex:
      // categories où la PK est id mais l'unicité métier est (shop_id, name)).
      final onConflict = op['onConflict'] as String?;
      switch (type) {
        case 'upsert':
          if (onConflict != null) {
            await _db.from(table).upsert(data, onConflict: onConflict);
          } else {
            await _db.from(table).upsert(data);
          }
        case 'delete': await _db.from(table).delete()
            .eq(op['col'] as String, op['val']);
        case 'insert': await _db.from(table).insert(data);
      }
      return true;
    } catch (e) {
      final err = e.toString();
      debugPrint('[DB] ✗ Op failed table=${op['table']} op=${op['op']} err=$err');

      // ── Erreurs PERMANENTES → supprimer de la queue (réessayer ne sert à rien)
      if (_isPermanentError(err)) {
        // Duplicate key (23505) = idempotence normale (rejeu offline d'une op
        // déjà appliquée par realtime, double-tap UI, etc.). On avale
        // silencieusement, sinon la bannière "Synchro incomplète" reste
        // affichée à vie alors que tout est cohérent côté serveur.
        if (err.contains('23505')) {
          debugPrint('[DB] 23505 ignoré (idempotence) → supprimé de la queue');
        } else {
          debugPrint('[DB] Erreur permanente → supprimé de la queue');
          _logSyncError(op, err); // journaliser pour débogage
        }
        return true;
      }

      // ── Table inexistante (42P01) → afficher le SQL de création
      if (err.contains('42P01') || err.contains('does not exist')) {
        final tbl = op['table'] as String? ?? '?';
        final sql = getSqlForTable(tbl);
        debugPrint('[DB] ⚠️ Table "$tbl" inexistante → op gardée en queue');
        if (sql != null) {
          debugPrint('[DB] 📋 Créez la table avec ce SQL dans Supabase > SQL Editor:\n$sql');
        }
        return false;
      }

      // ── Erreur temporaire (réseau, timeout) → garder en queue
      return false;
    }
  }

  /// Erreurs qui ne peuvent pas être résolues en réessayant
  static bool _isPermanentError(String err) =>
      err.contains('23505') || // duplicate key
          err.contains('23503') || // FK violation
          err.contains('42501') || // permission denied
          err.contains('42502') || // insufficient privilege
          err.contains('23502');   // not null violation

  /// Émet un bip + vibration pour signaler une erreur de sync à l'utilisateur
  /// (sans UI). Best-effort : si la plateforme ne supporte pas, on ignore.
  static void _alertUser() {
    try { SystemSound.play(SystemSoundType.alert); } catch (_) {}
    try { HapticFeedback.heavyImpact(); } catch (_) {}
  }

  /// Journaliser les erreurs de sync dans Hive pour consultation ultérieure.
  /// Conserve le payload `data` complet pour permettre un replay manuel
  /// (cf. UI Paramètres → Erreurs de synchronisation, à venir).
  static void _logSyncError(Map<String, dynamic> op, String error) {
    _alertUser();
    try {
      final logBox = HiveBoxes.settingsBox;
      final logs = List<Map>.from(
          (logBox.get('sync_errors') as List?) ?? []);

      // Déduplication par signature {table, op, val, code-erreur}.
      // Sans ça, une RLS bloquante (42501) répétée à chaque tentative
      // accumule des dizaines de doublons dans la liste — la bannière
      // "Synchro incomplète" donne l'impression que des dizaines d'ops
      // distinctes échouent alors qu'il s'agit toujours de la même.
      // On extrait juste le code Postgres (5 chiffres) pour la signature,
      // pour ne pas être sensible aux variations de message (timestamps, ids).
      final codeMatch = RegExp(r'\b(\d{5})\b').firstMatch(error);
      final codeKey = codeMatch?.group(1) ?? error.substring(
          0, error.length > 60 ? 60 : error.length);
      final sig = '${op['table']}|${op['op']}|${op['val']}|$codeKey';
      logs.removeWhere((e) {
        final eCodeMatch = RegExp(r'\b(\d{5})\b').firstMatch(
            e['error']?.toString() ?? '');
        final eCodeKey = eCodeMatch?.group(1) ?? (e['error']?.toString() ?? '')
            .substring(0, ((e['error']?.toString() ?? '').length > 60
                ? 60 : (e['error']?.toString() ?? '').length));
        final eSig = '${e['table']}|${e['op']}|${e['val']}|$eCodeKey';
        return eSig == sig;
      });

      logs.add({
        'table':  op['table'],
        'op':     op['op'],
        'col':    op['col'],
        'val':    op['val'],
        'data':   op['data'],   // ← payload complet pour replay
        'error':  error,
        'time':   DateTime.now().toIso8601String(),
      });
      // Garder seulement les 50 dernières erreurs
      if (logs.length > 50) logs.removeRange(0, logs.length - 50);
      logBox.put('sync_errors', logs);
    } catch (_) {}
  }

  /// Nombre total d'opérations en attente de sync (toutes tables).
  static int get pendingOpsCount => HiveBoxes.offlineQueueBox.length;

  /// Nombre de ventes / commandes en échec de sync depuis ≥ 10 tentatives.
  /// Utilisé par la bannière offline pour alerter l'utilisateur qu'il y a
  /// des transactions financières qui n'ont pas atteint Supabase.
  static int get stuckCriticalOpsCount {
    const criticalTables = {'orders', 'sales', 'expenses'};
    var n = 0;
    for (final raw in HiveBoxes.offlineQueueBox.values) {
      try {
        final m = Map<String, dynamic>.from(raw);
        final table = m['table'] as String? ?? '';
        final retries = (m['_retries'] as int?) ?? 0;
        if (criticalTables.contains(table) && retries >= 10) n++;
      } catch (_) {}
    }
    return n;
  }

  // Écrire en arrière-plan si online, sinon enqueue
  static void _bgWrite(Map<String, dynamic> op) {
    if (_i._isOnline) {
      _executeOp(op).then((ok) { if (!ok) _enqueue(op); })
          .catchError((e) { _enqueue(op); });
    } else {
      _enqueue(op);
    }
  }

  /// Insère une ligne dans une table via la file offline (réessayé au retour online).
  /// Utilisé par ActivityLogService pour que les logs d'action ne soient
  /// jamais perdus en mode hors-ligne.
  static void bgInsert(String table, Map<String, dynamic> data) {
    _bgWrite({'table': table, 'op': 'insert', 'data': data});
  }

  /// Supprime une ligne par sa clé via la file offline.
  /// Utilisé pour les services Hive-first qui doivent répliquer un delete.
  static void bgDelete(String table, {String col = 'id', required dynamic val}) {
    _bgWrite({'table': table, 'op': 'delete', 'col': col, 'val': val,
              'data': const {}});
  }


  // ══ DÉFINITIONS SQL DES TABLES ════════════════════════════════════════════════
  // Exécuter dans Supabase → SQL Editor si la table n'existe pas encore

  static const Map<String, String> _tableSql = {
    'orders': """
create table if not exists public.orders (
  id               text             primary key,
  shop_id          text             not null references public.shops(id) on delete cascade,
  status           text             not null default 'scheduled'
                   check (status in ('scheduled','processing','completed',
                                     'cancelled','refused','refunded')),
  items            jsonb            not null default '[]',
  discount_amount  double precision not null default 0,
  tax_rate         double precision not null default 0,
  payment_method   text             not null default 'cash',
  client_id        text,
  client_name      text,
  client_phone     text,
  notes            text,
  fees             jsonb            not null default '[]'::jsonb,
  scheduled_at     timestamptz,
  created_at       timestamptz      not null default now(),
  completed_at     timestamptz,
  synced_to_cloud  boolean          not null default false
);
create index if not exists orders_shop_id_idx on public.orders(shop_id);
create index if not exists orders_status_idx  on public.orders(status);
alter table public.orders enable row level security;
do \$\$ begin
  if not exists (select 1 from pg_policies where tablename='orders' and policyname='orders_members') then
    create policy "orders_members" on public.orders for all using (
      shop_id in (select shop_id from public.shop_memberships where user_id=(auth.uid())::text));
  end if;
end \$\$;""",

    'clients': """
create table if not exists public.clients (
  id          text primary key,
  store_id    text not null references public.shops(id) on delete cascade,
  name        text not null,
  phone       text,
  email       text,
  address     text,
  notes       text,
  tag         text default 'none',
  created_at  timestamptz not null default now(),
  unique(store_id, email),
  unique(store_id, phone)
);
alter table public.clients enable row level security;
do \$\$ begin
  if not exists (select 1 from pg_policies where tablename='clients' and policyname='clients_members') then
    create policy "clients_members" on public.clients for all using (
      store_id in (select shop_id from public.shop_memberships where user_id=(auth.uid())::text));
  end if;
end \$\$;""",

    'products': """
create table if not exists public.products (
  id          text primary key,
  shop_id     text not null references public.shops(id) on delete cascade,
  name        text not null,
  sku         text,
  barcode     text,
  category_id text,
  brand_id    text,
  price_sell  double precision default 0,
  price_buy   double precision default 0,
  stock       integer default 0,
  is_active   boolean default true,
  created_at  timestamptz not null default now(),
  data        jsonb default '{}'
);
alter table public.products enable row level security;
do \$\$ begin
  if not exists (select 1 from pg_policies where tablename='products' and policyname='products_members') then
    create policy "products_members" on public.products for all using (
      shop_id in (select shop_id from public.shop_memberships where user_id=(auth.uid())::text));
  end if;
end \$\$;""",
  };

  /// Retourne le SQL de création pour une table donnée.
  /// Afficher dans l'UI ou logger si la table est manquante.
  static String? getSqlForTable(String tableName) =>
      _tableSql[tableName];

  /// Retourne toutes les tables avec leur SQL
  static Map<String, String> get allTablesSql => Map.unmodifiable(_tableSql);

  // ══ AUTH ══════════════════════════════════════════════════════════

  static Future<void> saveProfile(UserModel user) async {
    await LocalStorageService.saveUser(user.toEntity());
    await LocalStorageService.setCurrentUserId(user.id);
    _bgWrite({'table': 'profiles', 'op': 'upsert',
      'data': {'id': user.id, 'name': user.name,
        'email': user.email, 'phone': user.phone}});
  }

  // ══ BOUTIQUES ═════════════════════════════════════════════════════

  /// Vérifie qu'aucune entité de stockage du même owner (boutique, magasin
  /// warehouse ou dépôt partenaire) ne porte déjà le nom donné. La
  /// comparaison est insensible à la casse et trimmée.
  ///
  /// `excludeShopId` permet d'ignorer la boutique en cours de modification
  /// (cas du renommage). La `StockLocation` type=shop associée est aussi
  /// exclue automatiquement (elle porte le même nom que sa boutique).
  ///
  /// Lance une [Exception] si le nom est déjà utilisé.
  static Future<void> _ensureLocationNameAvailable({
    required String userId,
    required String name,
    String? excludeShopId,
  }) async {
    final lowered = name.toLowerCase();

    // 1. Hive local — couvre l'offline + filet rapide.
    for (final raw in HiveBoxes.shopsBox.values) {
      final m = Map<String, dynamic>.from(raw);
      if (m['owner_id'] != userId) continue;
      if (excludeShopId != null && m['id'] == excludeShopId) continue;
      final n = (m['name'] ?? '').toString().trim().toLowerCase();
      if (n == lowered) {
        throw Exception('Vous avez déjà une boutique nommée "$name"');
      }
    }
    final excludeShopLocId =
        excludeShopId != null ? _shopLocationId(excludeShopId) : null;
    for (final loc in getStockLocationsForOwner(userId)) {
      if (loc.id == excludeShopLocId) continue;
      if (loc.name.trim().toLowerCase() != lowered) continue;
      switch (loc.type) {
        case StockLocationType.warehouse:
          throw Exception('Vous avez déjà un magasin nommé "$name"');
        case StockLocationType.partner:
          throw Exception(
              'Vous avez déjà un dépôt partenaire nommé "$name"');
        case StockLocationType.shop:
          throw Exception('Vous avez déjà une boutique nommée "$name"');
      }
    }

    // 2. Supabase — blinde si Hive n'est pas à jour. On ignore les erreurs
    //    réseau (offline-first) : l'utilisateur sera bloqué côté serveur si
    //    une autre session a créé un doublon entretemps.
    try {
      var shopsQ = _db.from('shops').select('id')
          .eq('owner_id', userId).ilike('name', name);
      if (excludeShopId != null) shopsQ = shopsQ.neq('id', excludeShopId);
      final shopHit = await shopsQ.maybeSingle();
      if (shopHit != null) {
        throw Exception('Vous avez déjà une boutique nommée "$name"');
      }
      var locsQ = _db.from('stock_locations').select('id, type')
          .eq('owner_id', userId).ilike('name', name)
          .neq('type', 'shop');
      if (excludeShopLocId != null) {
        locsQ = locsQ.neq('id', excludeShopLocId);
      }
      final locHit = await locsQ.maybeSingle();
      if (locHit != null) {
        final t = locHit['type']?.toString() ?? '';
        throw Exception(t == 'partner'
            ? 'Vous avez déjà un dépôt partenaire nommé "$name"'
            : 'Vous avez déjà un magasin nommé "$name"');
      }
    } on Exception {
      rethrow;
    } catch (e) {
      debugPrint('[DB] _ensureLocationNameAvailable Supabase: $e');
    }
  }

  static Future<ShopSummary> createShop({
    required String name, required String sector,
    required String currency, required String country,
    String? phone, String? email,
  }) async {
    final userId = _userId;
    if (userId == null) throw Exception('Connexion requise pour créer une boutique');

    final trimmed = name.trim();
    await _ensureLocationNameAvailable(
        userId: userId, name: trimmed);

    final row = await _db.from('shops').insert({
      'owner_id': userId, 'name': name, 'sector': sector,
      'currency': currency, 'country': country,
      'phone': phone, 'email': email, 'is_active': true,
    }).select().single();

    await _db.from('shop_memberships').insert(
        {'shop_id': row['id'], 'user_id': userId, 'role': 'owner'});

    final shop = _rowToShop(row);
    await LocalStorageService.saveShop(shop);
    await LocalStorageService.saveMembership(
        userId: userId, shopId: shop.id,
        shopName: shop.name, role: UserRole.admin);

    // Amorce la liste des membres avec le créateur pour qu'il apparaisse
    // immédiatement dans l'onglet Membres, même avant le 1er fetch Supabase.
    final profile = LocalStorageService.getCurrentUser();
    await HiveBoxes.settingsBox.put('members_${shop.id}', [{
      'user_id':   userId,
      'role':      'admin',
      'joined_at': DateTime.now().toIso8601String(),
      'profiles':  {
        'id':    userId,
        'name':  profile?.name  ?? '',
        'email': profile?.email ?? '',
        'phone': profile?.phone,
      },
    }]);

    debugPrint('[DB] ✅ Boutique créée: ${shop.name}');
    return shop;
  }

  /// Modifie les infos éditables d'une boutique (nom, secteur, pays, monnaie,
  /// téléphone, email). Valide l'unicité du nom par propriétaire avant update.
  /// Les champs à null sont ignorés (pas écrasés).
  static Future<ShopSummary> updateShop({
    required String shopId,
    String? name, String? sector,
    String? currency, String? country,
    String? phone, String? email,
  }) async {
    final userId = _userId;
    if (userId == null) throw Exception('Connexion requise pour modifier une boutique');

    // 1. Unicité du nom (seulement si le nom change) — couvre boutiques,
    //    magasins (warehouses) et dépôts partenaires du même owner.
    if (name != null && name.trim().isNotEmpty) {
      await _ensureLocationNameAvailable(
          userId: userId, name: name.trim(), excludeShopId: shopId);
    }

    // 2. Payload sans les nulls
    final payload = <String, dynamic>{};
    if (name     != null) payload['name']     = name.trim();
    if (sector   != null) payload['sector']   = sector;
    if (currency != null) payload['currency'] = currency;
    if (country  != null) payload['country']  = country;
    if (phone    != null) payload['phone']    = phone.trim().isEmpty ? null : phone.trim();
    if (email    != null) payload['email']    = email.trim().isEmpty ? null : email.trim();
    if (payload.isEmpty) {
      final cached = LocalStorageService.getShop(shopId);
      if (cached != null) return cached;
      throw Exception('Aucune modification à enregistrer');
    }

    // 3. Update Supabase → source de vérité
    final row = await _db.from('shops').update(payload)
        .eq('id', shopId).select().single();
    final updated = _rowToShop(row);

    // 4. Hive + notif listeners
    await LocalStorageService.saveShop(updated);
    _notify('shops', shopId);

    // 5. Synchroniser le nom de la StockLocation associée (type=shop)
    //    pour que les dropdowns / sliders / pages transferts reflètent
    //    immédiatement le nouveau nom de la boutique.
    if (name != null) {
      final shopLoc = getShopLocation(shopId);
      if (shopLoc != null && shopLoc.name != updated.name) {
        await saveStockLocation(shopLoc.copyWith(name: updated.name));
      }
    }

    debugPrint('[DB] ✅ Boutique modifiée: ${updated.name}');
    return updated;
  }

  /// Active / désactive une boutique (Hive immédiat + Supabase background).
  static Future<void> setShopActive(String shopId, bool active) async {
    final cached = LocalStorageService.getShop(shopId);
    if (cached != null) {
      final updated = ShopSummary(
        id: cached.id, name: cached.name, logoUrl: cached.logoUrl,
        currency: cached.currency, country: cached.country,
        sector: cached.sector, isActive: active,
        todaySales: cached.todaySales, ownerId: cached.ownerId,
        phone: cached.phone, email: cached.email,
        createdAt: cached.createdAt, members: cached.members,
        kind: cached.kind, parentShopId: cached.parentShopId,
      );
      await LocalStorageService.saveShop(updated);
    }
    _bgWrite({'table': 'shops', 'op': 'upsert',
      'data': {'id': shopId, 'is_active': active}});
    _notify('shops', shopId);
    debugPrint('[DB] ✅ Boutique $shopId is_active=$active');
  }

  static Future<List<ShopSummary>> getMyShops() async {
    final userId = _userId ?? LocalStorageService.getCurrentUser()?.id;
    if (userId == null) return [];
    try {
      final owned = await _db.from('shops').select().eq('owner_id', userId)
          .timeout(const Duration(seconds: 10));
      final mems  = await _db.from('shop_memberships')
          .select('role, shops(*)').eq('user_id', userId);

      final shops   = <ShopSummary>[];
      final seenIds = <String>{};

      for (final row in owned as List) {
        final s = _rowToShop(row);
        if (seenIds.add(s.id)) { shops.add(s); await _cacheShop(userId, s, UserRole.admin); }
      }
      for (final row in mems as List) {
        final shopRow = row['shops'];
        if (shopRow == null) continue;
        final s = _rowToShop(shopRow as Map<String, dynamic>);
        if (seenIds.add(s.id)) {
          final role = _parseRole(row['role'] ?? 'cashier');
          shops.add(s); await _cacheShop(userId, s, role);
        }
      }
      debugPrint('[DB] ${shops.length} boutiques');
      return shops;
    } catch (e) {
      debugPrint('[DB] Erreur getMyShops: $e');
      return LocalStorageService.getShopsForUser(userId);
    }
  }

  static Future<void> _cacheShop(String userId, ShopSummary s, UserRole role) async {
    await LocalStorageService.saveShop(s);
    await LocalStorageService.saveMembership(
        userId: userId, shopId: s.id, shopName: s.name, role: role);
  }

  // ══ PRODUITS ══════════════════════════════════════════════════════

  static Future<void> saveProduct(Product p, {
    bool skipValidation = false,
    bool skipStockLog   = false,
    bool forceStockLevelSync = false,
  }) async {
    if (p.id == null) return;

    // 0bis. Cohérence stockQty ↔ variantes : quand un produit a des variantes,
    //       son stockQty (champ persisté + Supabase) DOIT être la somme des
    //       stockAvailable. Sinon les écrans qui lisent stockQty (au lieu du
    //       getter totalStock) divergent du total réel — typiquement après
    //       une vente, une arrivée ou une édition de variantes via
    //       StockService._saveVariant qui ne touche pas stockQty.
    if (p.variants.isNotEmpty) {
      final sum = p.variants.fold<int>(0, (s, v) => s + v.stockAvailable);
      if (sum != p.stockQty) {
        p = p.copyWith(stockQty: sum);
      }
    }

    // 0. Validation unicité (SKU + nom) — seulement si online et pas skippée
    if (!skipValidation && _i._isOnline) {
      await _validateProductUniqueness(p);
    }

    // 1. Validation locale — SKU unique dans Hive
    if (!skipValidation) {
      _validateLocalUniqueness(p);
    }

    // 1bis. Diff stock AVANT le put — détecte les ajustements manuels via
    //       product_form (ou autres call sites). Ce log permet à l'historique
    //       de tracer l'origine de chaque variation, complémentaire des
    //       logs ventes/transferts/réceptions/incidents déjà émis ailleurs.
    final stockDiffs = !skipStockLog
        ? _computeStockDiffs(p)
        : const <_StockDiff>[];

    // 2. Hive IMMÉDIATEMENT — retour UI instantané.
    //    Invalidation synchrone du cache produits AVANT le `put` : sinon
    //    une lecture concurrente (StockService.sale dans une boucle multi-
    //    variantes) lirait l'ancien produit et écraserait l'écriture
    //    précédente. Le watcher async ne suffit pas (event loop pas encore
    //    propagé pendant la boucle de débit).
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    _i._recentLocalProductWrites[p.id!] = nowMs;
    // Purge léger : retirer les entrées plus vieilles que 2× la fenêtre.
    // Garde la map petite sans coûter à chaque écriture (suppression rapide
    // sur quelques entrées au plus).
    _i._recentLocalProductWrites.removeWhere(
        (_, ts) => nowMs - ts > _localWriteEchoWindowMs * 2);
    LocalStorageService.invalidateProductsCache();
    await HiveBoxes.productsBox.put(p.id!, _productToMap(p));

    // 3. Notifier les listeners locaux
    if (p.storeId != null) _notify('products', p.storeId!);

    // 4. Supabase en arrière-plan
    _bgWrite({'table': 'products', 'op': 'upsert', 'data': _productToSupabase(p)});

    // 5. Phase 5 : synchroniser les StockLevel de la boutique avec les
    //    variantes. Couvre ventes, arrivées, incidents, ajustements, retours,
    //    création/édition produit, etc. — tous passent par saveProduct.
    if (p.storeId != null) {
      await _syncShopStockLevelsFromProduct(p, force: forceStockLevelSync);
    }

    // 6. Persister les mouvements de stock détectés au step 1bis.
    //    Fait APRÈS le put pour garantir que tout consommateur lit la
    //    version finale (pas d'incohérence read-your-write).
    if (stockDiffs.isNotEmpty && p.storeId != null) {
      final user = LocalStorageService.getCurrentUser();
      for (final d in stockDiffs) {
        final mvt = StockMovement(
          id: 'sm_${DateTime.now().microsecondsSinceEpoch}_${d.variantId}',
          shopId:    p.storeId!,
          productId: p.id,
          variantId: d.variantId,
          type:      d.isCreation
              ? StockMovementType.entry
              : StockMovementType.adjustment,
          quantity:  d.delta,
          createdBy: user?.name,
          createdAt: DateTime.now(),
          notes:     d.isCreation
              ? 'Stock initial à la création'
              : 'Ajustement manuel via fiche produit '
                '(${d.before} → ${d.after})',
        );
        try {
          await HiveBoxes.stockMovementsBox.put(mvt.id, mvt.toMap());
          _bgWrite({'table': 'stock_movements', 'op': 'upsert',
              'data': mvt.toMap()});
          _notify('stock_movements', p.storeId!);
        } catch (e) {
          debugPrint('[DB] saveProduct stock log error: $e');
        }
      }
    }
  }

  /// Diff stockAvailable de chaque variante entre le produit déjà en Hive
  /// et celui qu'on s'apprête à sauver. Utilisé pour générer un log
  /// stock_movement quand un user édite un stock manuellement (cas non
  /// couvert par les logs ventes/transferts/réceptions automatiques).
  static List<_StockDiff> _computeStockDiffs(Product p) {
    if (p.id == null) return const [];
    final out = <_StockDiff>[];
    final existingRaw = HiveBoxes.productsBox.get(p.id!);
    if (existingRaw == null) {
      // Création : tout stock initial > 0 = entrée.
      for (final v in p.variants) {
        if (v.id == null || v.id!.isEmpty) continue;
        if (v.stockAvailable > 0) {
          out.add(_StockDiff(
              variantId: v.id!,
              before: 0, after: v.stockAvailable,
              isCreation: true));
        }
      }
      return out;
    }
    try {
      final existing = LocalStorageService.productFromMap(
          Map<String, dynamic>.from(existingRaw));
      final beforeByVid = <String, int>{};
      for (final v in existing.variants) {
        if (v.id != null) beforeByVid[v.id!] = v.stockAvailable;
      }
      for (final v in p.variants) {
        if (v.id == null || v.id!.isEmpty) continue;
        final before = beforeByVid[v.id!] ?? 0;
        final after  = v.stockAvailable;
        if (before == after) continue;
        out.add(_StockDiff(
            variantId: v.id!,
            before: before, after: after,
            isCreation: !beforeByVid.containsKey(v.id!)));
      }
    } catch (_) {/* ignore — pas de log si on ne peut pas diff */}
    return out;
  }

  /// Force `is_visible_web=true` sur une liste de produits.
  /// Utilisé par le partage catalogue WhatsApp pour s'assurer que la RLS
  /// publique (`products_anon_read_visible_web`) laissera passer la lecture
  /// anonyme via le lien partagé. Update Hive immédiat + push Supabase
  /// en arrière-plan via la file offline.
  static Future<void> markProductsVisibleWeb(List<Product> products) async {
    if (products.isEmpty) return;
    for (final p in products) {
      if (p.id == null || p.isVisibleWeb) continue;
      final updated = p.copyWith(isVisibleWeb: true);
      // saveProduct fait Hive + bgWrite + sync StockLevels — tout en un.
      await saveProduct(updated, skipValidation: true);
    }
  }

  /// Pour chaque variante d'un produit, met à jour le `StockLevel`
  /// correspondant à la boutique (location type=shop).
  /// Crée le StockLevel s'il n'existe pas. Silencieux si la boutique
  /// n'a pas encore de shopLocation (cas d'une boutique créée hors migration).
  static Future<void> _syncShopStockLevelsFromProduct(Product p,
      {bool force = false}) async {
    final shopId = p.storeId;
    if (shopId == null) return;
    final shopLoc = getShopLocation(shopId);
    if (shopLoc == null) return;

    final now = DateTime.now();
    final nowMs = now.millisecondsSinceEpoch;
    for (final v in p.variants) {
      final vid = v.id;
      if (vid == null || vid.isEmpty) continue;
      final lvlId = _stockLevelId(vid, shopLoc.id);
      // Anti-stale persistant : si on a écrit ce StockLevel localement
      // dans le TTL `_kStockLevelEchoTtlMs` (1 h, persisté en settingsBox),
      // ne pas écraser depuis la variante — la valeur fraîche reste la
      // nôtre. Sans ça, un pull syncProducts immédiat après un transfert
      // undo le décrément côté StockLevel boutique (= « stock reste à
      // l'ancien emplacement »).
      // EXCEPTION : `force=true` (édition utilisateur explicite via la
      // fiche produit) bypass cet anti-stale — l'utilisateur a délibéré-
      // ment redéfini le stock, sa valeur PRIME sur tout transfert récent.
      // Sans ça, l'écran "vue boutique" restait sur l'ancien StockLevel
      // alors que `variant.stockAvailable` venait d'être mise à jour →
      // « stock global > somme variantes » visuel.
      if (!force) {
        final recentMs = _i._recentLocalStockLevelWrites[lvlId];
        if (recentMs != null
            && nowMs - recentMs < _kStockLevelEchoTtlMs) {
          continue;
        }
      }
      final existingRaw = HiveBoxes.stockLevelsBox.get(lvlId);

      if (existingRaw != null) {
        final existing = StockLevel.fromMap(
            Map<String, dynamic>.from(existingRaw));
        // Pas d'écriture si déjà synchronisé (évite notif + bgWrite inutile)
        if (existing.stockAvailable == v.stockAvailable &&
            existing.stockPhysical  == v.stockPhysical  &&
            existing.stockBlocked   == v.stockBlocked   &&
            existing.stockOrdered   == v.stockOrdered) {
          continue;
        }
        final updated = existing.copyWith(
          stockAvailable: v.stockAvailable,
          stockPhysical:  v.stockPhysical,
          stockBlocked:   v.stockBlocked,
          stockOrdered:   v.stockOrdered,
          updatedAt:      now,
        );
        await saveStockLevel(updated);
      } else {
        final created = StockLevel(
          id:             lvlId,
          variantId:      vid,
          locationId:     shopLoc.id,
          shopId:         shopId,
          stockAvailable: v.stockAvailable,
          stockPhysical:  v.stockPhysical,
          stockBlocked:   v.stockBlocked,
          stockOrdered:   v.stockOrdered,
          updatedAt:      now,
        );
        await saveStockLevel(created);
      }
    }
  }

  /// Validation locale rapide : SKU unique dans le cache Hive
  static void _validateLocalUniqueness(Product p) {
    final shopId = p.storeId;
    if (shopId == null) return;
    final skus = p.variants
        .where((v) => v.sku != null && v.sku!.isNotEmpty)
        .map((v) => v.sku!.toLowerCase())
        .toSet();
    if (skus.isEmpty) return;

    for (final raw in HiveBoxes.productsBox.values) {
      try {
        final m = Map<String, dynamic>.from(raw);
        if (m['store_id'] != shopId || m['id'] == p.id) continue;
        final variants = m['variants'] as List? ?? [];
        for (final v in variants) {
          final existingSku = ((v as Map)['sku'] as String?)?.toLowerCase();
          if (existingSku != null && skus.contains(existingSku)) {
            throw Exception(
                'Le SKU "$existingSku" est déjà utilisé par "${m['name']}"');
          }
        }
      } catch (e) {
        if (e is Exception && e.toString().contains('SKU')) rethrow;
      }
    }
  }

  static Future<void> _validateProductUniqueness(Product p) async {
    final shopId = p.storeId;
    if (shopId == null) return;

    // Collecter tous les SKU de toutes les variantes du produit à sauvegarder
    final skus = p.variants
        .where((v) => v.sku != null && v.sku!.isNotEmpty)
        .map((v) => v.sku!.toLowerCase())
        .toSet();

    // Vérifier l'unicité des SKU dans la boutique
    if (skus.isNotEmpty) {
      final rows = await _db.from('products').select('id, name, variants')
          .eq('store_id', shopId).neq('id', p.id ?? '');
      for (final row in rows as List) {
        for (final v in (row['variants'] as List?) ?? []) {
          final existingSku = (v['sku'] as String?)?.toLowerCase();
          if (existingSku != null && skus.contains(existingSku)) {
            throw Exception(
                'Le SKU "$existingSku" est déjà utilisé par "${row['name']}"');
          }
        }
      }
    }

    // Vérifier l'unicité du nom de produit
    final nr = await _db.from('products').select('id')
        .eq('store_id', shopId).ilike('name', p.name.trim())
        .neq('id', p.id ?? '').maybeSingle();
    if (nr != null) throw Exception('Un produit nommé "${p.name}" existe déjà');
  }

  static Future<void> deleteProduct(String productId) async {
    // Lire le shopId AVANT delete pour pouvoir notifier ensuite
    final raw = HiveBoxes.productsBox.get(productId);
    final shopId = raw is Map ? raw['store_id'] as String? : null;
    final prodName = raw is Map ? (raw['name'] as String? ?? '') : '';

    // Règle métier : refuser la suppression si le produit ou une de ses
    // variantes est référencé dans une commande. On préserve l'historique.
    final variantIds = <String>{};
    if (raw is Map) {
      final vars = (raw['variants'] as List?) ?? [];
      for (final v in vars) {
        final vid = (v as Map)['id'] as String?;
        if (vid != null && vid.isNotEmpty) variantIds.add(vid);
      }
    }
    bool usedInOrders = false;
    for (final orderRaw in HiveBoxes.ordersBox.values) {
      final om = Map<String, dynamic>.from(orderRaw);
      final items = (om['items'] as List?) ?? [];
      for (final it in items) {
        final pid = (it as Map)['product_id']?.toString();
        if (pid == productId || variantIds.contains(pid)) {
          usedInOrders = true; break;
        }
      }
      if (usedInOrders) break;
    }
    if (usedInOrders) {
      throw Exception(
          'Impossible de supprimer "${prodName.isEmpty ? 'ce produit' : prodName}" : '
          'il est référencé dans au moins une commande. Supprime/annule les '
          'commandes concernées d\'abord, ou désactive ce produit à la place.');
    }

    LocalStorageService.invalidateProductsCache();
    await HiveBoxes.productsBox.delete(productId);
    // Tombstone persistant : empêche les sync/realtime futurs de
    // ressusciter ce produit si la propagation Supabase a un retard ou
    // si un autre device pousse en parallèle un snapshot pré-suppression.
    await _markProductDeletionPending(productId);
    if (shopId != null) _notify('products', shopId);
    _bgWrite({'table': 'products', 'op': 'delete',
      'col': 'id', 'val': productId, 'data': {'id': productId}});
  }

  static List<Product> getProductsForShop(String shopId) =>
      LocalStorageService.getProductsForShop(shopId)
          .where((p) => p.id != null).toList();

  static Future<void> syncProducts(String shopId) async {
    try {
      // Vérifier que la session est valide
      final session = _db.auth.currentSession;
      debugPrint('[DB] syncProducts shopId=' + shopId + ' session=' + (session != null ? 'OK' : 'NULL'));

      final rows = await _db.from('products').select().eq('store_id', shopId)
          .timeout(const Duration(seconds: 10));
      final remoteIds = <String>{};

      final rowList = rows as List;
      debugPrint('[DB] syncProducts ' + shopId + ' -> ' + rowList.length.toString() + ' produits Supabase');
      if (rowList.isNotEmpty) {
        debugPrint('[DB] 1er produit: id=' + (rowList.first['id']?.toString() ?? '?') + ' name=' + (rowList.first['name']?.toString() ?? '?'));
      }
      for (final row in rowList) {
        final p = _supabaseToProduct(row);
        if (p.id == null) { debugPrint('[DB] ⚠️ produit sans id: $row'); continue; }
        remoteIds.add(p.id!);
        // Tombstone : on a supprimé ce produit localement mais le remote
        // l'a (encore). Ignorer cette ligne pour ne pas le ressusciter en
        // Hive — la queue DELETE s'en occupera côté Supabase.
        if (_isProductDeletionPending(p.id!)) {
          debugPrint('[DB] ⏭️ syncProducts tombstone product=${p.id}');
          continue;
        }
        // Anti-stale via row_version (cf. migration 015). On compare la
        // version qui revient de Supabase à celle qu'on a en cache local.
        // Si remote <= local → snapshot pull obsolète (cas typique :
        // débit multi-variantes en cours), on garde la version locale.
        final remoteVersion =
            (row['row_version'] as num?)?.toInt() ?? 0;
        final localRaw = HiveBoxes.productsBox.get(p.id!);
        if (localRaw is Map) {
          final localVersion =
              (localRaw['_row_version'] as num?)?.toInt() ?? 0;
          if (remoteVersion <= localVersion && remoteVersion > 0) {
            debugPrint('[DB] ⏭️ syncProducts stale '
                '(remote v=$remoteVersion <= local v=$localVersion) '
                'product=${p.id}');
            continue;
          }
        }
        // Filet écho temporel pour la transition (avant que la 1re version
        // remote ne soit disponible).
        final recentMs = _i._recentLocalProductWrites[p.id!];
        if (recentMs != null && remoteVersion == 0) {
          final age = DateTime.now().millisecondsSinceEpoch - recentMs;
          if (age < _localWriteEchoWindowMs) {
            debugPrint('[DB] ⏭️ syncProducts écho temporel ${age}ms '
                'product=${p.id}');
            continue;
          }
        }
        // Écrire dans Hive — Hive est le pont de lecture pour toute l'app
        final mapToWrite = _productToMap(p)
          ..['_row_version'] = remoteVersion;
        await HiveBoxes.productsBox.put(p.id!, mapToWrite);
        // Phase 5 : aligner le StockLevel de la boutique avec la variante
        // telle qu'elle arrive de Supabase (sinon divergence sur ce device
        // après une vente faite depuis un autre device ou une correction
        // distante).
        await _syncShopStockLevelsFromProduct(p);
      }
      debugPrint('[DB] syncProducts ' + shopId + ' -> ' + remoteIds.length.toString() + ' dans Hive');

      // Supprimer de Hive les produits effacés dans Supabase
      // SEULEMENT si remoteIds n'est pas vide (évite de tout supprimer si Supabase retourne vide)
      if (remoteIds.isNotEmpty) {
        final hiveKeys = HiveBoxes.productsBox.keys
            .where((k) {
          final raw = HiveBoxes.productsBox.get(k);
          if (raw == null) return false;
          final m = Map<String, dynamic>.from(raw);
          return m['store_id'] == shopId;
        }).toList();

        for (final key in hiveKeys) {
          if (!remoteIds.contains(key.toString())) {
            // Anti-écho : si une écriture locale très récente existe pour ce
            // produit, c'est très probablement un produit qui n'est pas
            // encore arrivé sur Supabase (latence d'upsert) — ne pas le
            // supprimer aveuglément.
            final recentMs = _i._recentLocalProductWrites[key.toString()];
            if (recentMs != null) {
              final age = DateTime.now().millisecondsSinceEpoch - recentMs;
              if (age < _localWriteEchoWindowMs) continue;
            }
            await HiveBoxes.productsBox.delete(key);
            debugPrint('[DB] Produit supprimé de Hive (absent Supabase): $key');
          }
        }
      }

      debugPrint('[DB] Produits sync: $shopId (${remoteIds.length} produits)');
      _notify('products', shopId);

      // Migration Phase 1 : stocks → StockLocation + StockLevel. Idempotent,
      // ne tourne qu'une fois par boutique grâce à un flag dans settingsBox.
      await migrateShopStocksToLocationsV1(shopId);
    } catch (e, st) {
      debugPrint('[DB] syncProducts ERROR: $e');
      debugPrint('[DB] syncProducts STACK: $st');
    }
  }

  // ══ STOCK MULTI-LOCATION (Phase 1) ═══════════════════════════════════
  // Lectures : synchrones depuis Hive. Écritures : Hive immédiat + bg Supabase.
  // Source de vérité future (Phase 2+) pour le stock par emplacement. Pendant
  // la Phase 1, les champs stockXxx de ProductVariant restent le fallback.

  // ─── Stock locations ─────────────────────────────────────────────────

  /// ID déterministe de la location type='shop' liée à une boutique.
  /// Permet l'idempotence entre devices qui migrent en parallèle.
  static String _shopLocationId(String shopId) => 'loc_shop_$shopId';

  /// Crée (ou récupère) la location type='shop' pour une boutique.
  /// N'écrit PAS vers Supabase seule — c'est `migrateShopStocksToLocationsV1`
  /// ou `saveStockLocation` qui le font.
  static StockLocation _ensureShopLocation({
    required String shopId,
    required String ownerId,
    required String shopName,
  }) {
    final locId = _shopLocationId(shopId);
    final existing = HiveBoxes.stockLocationsBox.get(locId);
    if (existing != null) {
      return StockLocation.fromMap(Map<String, dynamic>.from(existing));
    }
    final loc = StockLocation(
      id: locId,
      ownerId: ownerId,
      type: StockLocationType.shop,
      name: shopName,
      shopId: shopId,
      createdAt: DateTime.now(),
    );
    HiveBoxes.stockLocationsBox.put(locId, loc.toMap());
    // Pousser aussi vers Supabase. Sans ça, tous les `stock_levels` qui
    // référencent cette location échouent en 42501 (la sub-query RLS de
    // stock_levels ne trouve pas la location côté serveur). Le fait que
    // _bgWrite soit fire-and-forget convient ici : si on est offline, l'op
    // est mise en queue et flushera dès le retour réseau, débloquant
    // ensuite tous les stock_levels en attente.
    _bgWrite({'table': 'stock_locations', 'op': 'upsert',
        'data': loc.toMap()});
    _notify('stock_locations', shopId);
    return loc;
  }

  /// Lit depuis Hive la location type='shop' liée à la boutique. Null si absente.
  static StockLocation? getShopLocation(String shopId) {
    final raw = HiveBoxes.stockLocationsBox.get(_shopLocationId(shopId));
    if (raw == null) return null;
    return StockLocation.fromMap(Map<String, dynamic>.from(raw));
  }

  /// Toutes les locations d'un propriétaire (shops + warehouses + partners).
  static List<StockLocation> getStockLocationsForOwner(String ownerId) =>
      HiveBoxes.stockLocationsBox.values
          .map((m) => StockLocation.fromMap(Map<String, dynamic>.from(m)))
          .where((l) => l.ownerId == ownerId)
          .toList()
        ..sort((a, b) {
          final typeOrder = a.type.index.compareTo(b.type.index);
          return typeOrder != 0 ? typeOrder : a.name.compareTo(b.name);
        });

  /// Enregistre une location : Hive immédiat + bg Supabase.
  static Future<void> saveStockLocation(StockLocation loc) async {
    await HiveBoxes.stockLocationsBox.put(loc.id, loc.toMap());
    _bgWrite({'table': 'stock_locations', 'op': 'upsert', 'data': loc.toMap()});
    _notify('stock_locations', loc.shopId ?? loc.ownerId);
  }

  static Future<void> deleteStockLocation(String locId) async {
    final raw = HiveBoxes.stockLocationsBox.get(locId);
    await HiveBoxes.stockLocationsBox.delete(locId);
    _bgWrite({'table': 'stock_locations', 'op': 'delete',
      'col': 'id', 'val': locId, 'data': {}});
    if (raw is Map) {
      final shopId = raw['shop_id'] as String?;
      final ownerId = raw['owner_id'] as String? ?? '';
      _notify('stock_locations', shopId ?? ownerId);
    }
  }

  /// Pull les locations du user courant depuis Supabase → Hive.
  static Future<void> syncStockLocations() async {
    final userId = _userId;
    if (userId == null) return;
    try {
      final rows = await _db.from('stock_locations').select()
          .eq('owner_id', userId)
          .timeout(const Duration(seconds: 10));

      // 1. Upsert toutes les locations remote dans Hive + collecter leurs IDs.
      final remoteIds = <String>{};
      final list = rows as List;
      for (final row in list) {
        final loc = StockLocation.fromMap(Map<String, dynamic>.from(row));
        await HiveBoxes.stockLocationsBox.put(loc.id, loc.toMap());
        remoteIds.add(loc.id);
      }

      // 2. Purge defensive des partenaires stale en Hive : tout `partner`
      //    qui n'est pas dans la réponse Supabase pour cet user n'a aucune
      //    raison d'être visible. Cas typiques :
      //      a) Le partenaire appartenait à un autre compte utilisé sur le
      //         même device avant un logout/login (Hive n'est pas purgé).
      //      b) Le partenaire a été supprimé sur Supabase depuis un autre
      //         device et n'a pas été notifié à celui-ci.
      //      c) Un ownership a changé côté serveur sans propagation locale.
      //    On ne touche PAS aux `shop` ni aux `warehouse` (cycles de vie
      //    différents, gérés par _ensureShopLocation et la logique dépôts).
      final toRemove = <dynamic>[];
      for (final key in HiveBoxes.stockLocationsBox.keys) {
        final raw = HiveBoxes.stockLocationsBox.get(key);
        if (raw == null) continue;
        try {
          final loc = StockLocation.fromMap(Map<String, dynamic>.from(raw));
          if (loc.type == StockLocationType.partner
              && !remoteIds.contains(loc.id)) {
            toRemove.add(key);
          }
        } catch (_) {/* skip ligne corrompue */}
      }
      for (final key in toRemove) {
        await HiveBoxes.stockLocationsBox.delete(key);
      }

      debugPrint('[DB] syncStockLocations -> ${list.length} kept, '
          '${toRemove.length} stale partners purged');
    } catch (e) {
      debugPrint('[DB] syncStockLocations error: $e');
    }
  }

  // ─── Stock levels ────────────────────────────────────────────────────

  /// ID déterministe (variante × location) — évite les doublons entre devices.
  static String _stockLevelId(String variantId, String locationId) =>
      'lvl_${variantId}_$locationId';

  static StockLevel? getStockLevel(String variantId, String locationId) {
    final raw = HiveBoxes.stockLevelsBox.get(_stockLevelId(variantId, locationId));
    if (raw == null) return null;
    return StockLevel.fromMap(Map<String, dynamic>.from(raw));
  }

  static List<StockLevel> getStockLevelsForVariant(String variantId) =>
      HiveBoxes.stockLevelsBox.values
          .map((m) => StockLevel.fromMap(Map<String, dynamic>.from(m)))
          .where((l) => l.variantId == variantId)
          .toList();

  static List<StockLevel> getStockLevelsForLocation(String locationId) =>
      HiveBoxes.stockLevelsBox.values
          .map((m) => StockLevel.fromMap(Map<String, dynamic>.from(m)))
          .where((l) => l.locationId == locationId)
          .toList();

  static Future<void> saveStockLevel(StockLevel lvl) async {
    await HiveBoxes.stockLevelsBox.put(lvl.id, lvl.toMap());
    // Marqueur d'écho temporel : empêche tout sync remote dans la
    // fenêtre suivante d'écraser cette valeur (cf. _recentLocalStockLevelWrites).
    // PERSISTÉ dans settingsBox pour survivre à un reload navigateur :
    // sans ça, un transfert offline puis un cold start résultait en perte
    // de l'écho, donc remote (vieux) écrasait local (frais) au prochain pull.
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    _i._recentLocalStockLevelWrites[lvl.id] = nowMs;
    _i._recentLocalStockLevelWrites.removeWhere(
        (_, ts) => nowMs - ts > _kStockLevelEchoTtlMs);
    await _persistStockLevelEchoes();
    // onConflict : la table porte une contrainte unique métier
    // (variant_id, location_id). Sans ça, l'upsert se résout sur la PK id
    // et déclenche un 23505 si un row existe déjà avec mêmes
    // (variant_id, location_id) mais un id différent (autre device,
    // migration, etc.).
    _bgWrite({
      'table': 'stock_levels',
      'op': 'upsert',
      'data': lvl.toMap(),
      'onConflict': 'variant_id,location_id',
    });
    _notify('stock_levels', lvl.shopId ?? lvl.locationId);
  }

  /// Pull les niveaux de stock visibles par l'utilisateur depuis Supabase → Hive.
  ///
  /// On NE filtre PAS par `shop_id` : les stock_levels des partenaires
  /// (`StockLocation type='partner'`) ont `shop_id = NULL` car les partenaires
  /// ne sont pas rattachés à une shop. La RLS côté Supabase filtre déjà sur
  /// `location_id IN (locations dont l'owner est l'utilisateur)`, donc une
  /// requête sans filtre WHERE retourne uniquement ce que l'utilisateur a
  /// le droit de voir — boutique + partenaires.
  static Future<void> syncStockLevels(String shopId) async {
    debugPrint('[DB] syncStockLevels shop=$shopId : start');
    try {
      final rows = await _db.from('stock_levels').select()
          .timeout(const Duration(seconds: 10));
      final list = rows as List;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      int skippedEcho = 0;
      for (final row in list) {
        final lvl = StockLevel.fromMap(Map<String, dynamic>.from(row));
        // Anti-stale persistant : si on a écrit cette ligne localement
        // dans le TTL `_kStockLevelEchoTtlMs` (1 h), le remote est presque
        // certainement en retard. La map est rechargée depuis settingsBox
        // au boot, donc cet anti-stale survit à un reload navigateur ou
        // un cold start mobile pendant qu'un bgWrite est en queue.
        final recentMs = _i._recentLocalStockLevelWrites[lvl.id];
        if (recentMs != null
            && nowMs - recentMs < _kStockLevelEchoTtlMs) {
          skippedEcho++;
          continue;
        }
        await HiveBoxes.stockLevelsBox.put(lvl.id, lvl.toMap());
      }
      if (skippedEcho > 0) {
        debugPrint('[DB] syncStockLevels shop=$shopId : '
            '$skippedEcho ligne(s) skipped (echo écriture locale récente)');
      }
      debugPrint('[DB] syncStockLevels shop=$shopId -> ${list.length} niveaux');
    } catch (e) {
      debugPrint('[DB] syncStockLevels error: $e');
    }
  }

  // ─── Stock transfers ─────────────────────────────────────────────────

  static Future<void> saveStockTransfer(StockTransfer t) async {
    await HiveBoxes.stockTransfersBox.put(t.id, t.toMap());
    _bgWrite({'table': 'stock_transfers', 'op': 'upsert', 'data': t.toMap()});
    _notify('stock_transfers', t.ownerId);
  }

  static StockTransfer? getStockTransferById(String id) {
    final raw = HiveBoxes.stockTransfersBox.get(id);
    if (raw == null) return null;
    return StockTransfer.fromMap(Map<String, dynamic>.from(raw));
  }

  static List<StockTransfer> getStockTransfersForOwner(String ownerId) =>
      HiveBoxes.stockTransfersBox.values
          .map((m) => StockTransfer.fromMap(Map<String, dynamic>.from(m)))
          .where((t) => t.ownerId == ownerId)
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  static List<StockTransfer> getTransfersForLocation(String locationId) =>
      HiveBoxes.stockTransfersBox.values
          .map((m) => StockTransfer.fromMap(Map<String, dynamic>.from(m)))
          .where((t) => t.fromLocationId == locationId
                     || t.toLocationId == locationId)
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  /// Pull les transferts du user courant depuis Supabase → Hive.
  static Future<void> syncStockTransfers() async {
    final userId = _userId;
    if (userId == null) return;
    try {
      final rows = await _db.from('stock_transfers').select()
          .eq('owner_id', userId)
          .timeout(const Duration(seconds: 10));
      for (final row in rows as List) {
        final t = StockTransfer.fromMap(Map<String, dynamic>.from(row));
        await HiveBoxes.stockTransfersBox.put(t.id, t.toMap());
      }
      debugPrint('[DB] syncStockTransfers -> ${(rows as List).length} transferts');
    } catch (e) {
      debugPrint('[DB] syncStockTransfers error: $e');
    }
  }

  // ─── Migration one-shot (Phase 1) ────────────────────────────────────

  // v1d : diagnostic des variantes sans id skippées (ajout des logs détaillés).
  static const _kMigrationV1FlagPrefix = 'migrated_to_locations_v1d_';

  /// Migre les stocks existants d'une boutique vers le nouveau modèle.
  /// - Crée une `StockLocation` type='shop' pour la boutique si absente.
  /// - Crée un `StockLevel` par variante en copiant les 4 valeurs de stock
  ///   actuelles (stockAvailable/physical/blocked/ordered).
  ///
  /// Ordonnancement Supabase (crucial pour RLS) : on AWAITE explicitement
  /// l'upsert de la location AVANT d'envoyer les levels, car la policy RLS
  /// des stock_levels interroge stock_locations. Un INSERT parallèle via
  /// bgWrite peut arriver avant que la location ne soit commit → refus RLS.
  ///
  /// Idempotent : flag par boutique dans settingsBox. Ne modifie PAS les
  /// tables existantes (products, variants, shops). Sans danger.
  static Future<void> migrateShopStocksToLocationsV1(String shopId) async {
    final flagKey = '$_kMigrationV1FlagPrefix$shopId';
    if (HiveBoxes.settingsBox.get(flagKey) == true) return;

    final shop = LocalStorageService.getShop(shopId);
    if (shop == null) return;
    final ownerId = shop.ownerId ?? _userId ?? '';
    if (ownerId.isEmpty) return;

    // 1. Garantir la location type='shop' côté Hive
    final location = _ensureShopLocation(
      shopId:   shopId,
      ownerId:  ownerId,
      shopName: shop.name,
    );

    // 2. Pousser la location Supabase en AWAITANT (requis avant les levels)
    if (_i._isOnline) {
      try {
        await _db.from('stock_locations').upsert(location.toMap())
            .timeout(const Duration(seconds: 10));
      } catch (e) {
        debugPrint('[DB] Migration v1 shop=$shopId : location upsert KO ($e), '
            'on réessaiera au prochain syncProducts.');
        return; // flag non posé → retry au prochain sync
      }
    } else {
      // Offline : pousser via la queue FIFO, mais ne pas poser le flag
      // (la migration se finalisera au retour online).
      _bgWrite({'table': 'stock_locations', 'op': 'upsert',
        'data': location.toMap()});
    }

    // 3. Collecter tous les levels (depuis la variante = source de vérité
    //    Phase 1). On re-pousse TOUJOURS, même si un StockLevel existe déjà
    //    dans Hive : ça garantit la convergence si un retry après échec
    //    Supabase est nécessaire. L'upsert est idempotent (ID déterministe).
    final products = LocalStorageService.getProductsForShop(shopId);
    final levelMaps = <Map<String, dynamic>>[];
    int created = 0;
    int totalVariants = 0;
    int skippedNoId   = 0;
    for (final p in products) {
      for (final v in p.variants) {
        totalVariants++;
        final vid = v.id;
        if (vid == null || vid.isEmpty) {
          skippedNoId++;
          debugPrint('[DB] Migration v1 shop=$shopId : variante sans id skippée '
              '→ produit="${p.name}" (id=${p.id}), variante="${v.name}"');
          continue;
        }
        final lvlId = _stockLevelId(vid, location.id);
        final wasMissing = !HiveBoxes.stockLevelsBox.containsKey(lvlId);
        final lvl = StockLevel(
          id:             lvlId,
          variantId:      vid,
          locationId:     location.id,
          shopId:         shopId,
          stockAvailable: v.stockAvailable,
          stockPhysical:  v.stockPhysical,
          stockBlocked:   v.stockBlocked,
          stockOrdered:   v.stockOrdered,
          updatedAt:      DateTime.now(),
        );
        await HiveBoxes.stockLevelsBox.put(lvl.id, lvl.toMap());
        levelMaps.add(lvl.toMap());
        if (wasMissing) created++;
      }
    }
    if (skippedNoId > 0) {
      debugPrint('[DB] Migration v1 shop=$shopId : $skippedNoId variantes '
          'sur $totalVariants skippées faute d\'id.');
    }

    // 4. Bulk upsert des levels en une seule requête (await, après location)
    if (levelMaps.isNotEmpty) {
      if (_i._isOnline) {
        try {
          await _db.from('stock_levels').upsert(
              levelMaps, onConflict: 'variant_id,location_id')
              .timeout(const Duration(seconds: 20));
        } catch (e) {
          debugPrint('[DB] Migration v1 shop=$shopId : levels upsert KO ($e)');
          return; // flag non posé → retry au prochain sync
        }
      } else {
        for (final m in levelMaps) {
          _bgWrite({
            'table': 'stock_levels',
            'op': 'upsert',
            'data': m,
            'onConflict': 'variant_id,location_id',
          });
        }
        // Offline : on ne pose pas le flag, la queue se videra au retour online
        // et la prochaine passe posera le flag si tout est bien parti.
        debugPrint('[DB] Migration v1 shop=$shopId : offline, $created niveaux '
            'en queue. Le flag sera posé au prochain sync online.');
        return;
      }
    }

    // 5. Pose le flag : migration finalisée avec succès
    await HiveBoxes.settingsBox.put(flagKey, true);
    debugPrint('[DB] ✅ Migration stock v1 shop=$shopId : location + '
        '${levelMaps.length} niveaux poussés Supabase (dont $created nouveaux)');
  }

  // ══ ACTIVITY LOGS ═════════════════════════════════════════════════
  // Cache offline-first + realtime. Les lectures partent de Hive, le sync
  // en arrière-plan complète les logs anciens, et la realtime pousse les
  // nouvelles lignes dès qu'elles sont créées côté Supabase.

  /// Synchroniser les logs d'activité d'une boutique (pull depuis Supabase
  /// → Hive). Résout les noms d'acteurs depuis `profiles` en une seule
  /// requête pour éviter les N+1.
  static Future<void> syncActivityLogs(String shopId) async {
    try {
      if (!Hive.isBoxOpen(HiveBoxes.activityLogs)) return;
      final session = _db.auth.currentSession;
      if (session == null) return;

      final rows = List<Map<String, dynamic>>.from(
          await _db.from('activity_logs')
              .select('id,action,actor_id,actor_email,target_type,target_id,'
                      'target_label,shop_id,details,created_at')
              .eq('shop_id', shopId)
              .order('created_at', ascending: false)
              .limit(500)
              .timeout(const Duration(seconds: 10)) as List);

      // Résoudre les noms d'acteurs en une seule requête
      final actorIds = rows
          .map((r) => r['actor_id'] as String?)
          .whereType<String>()
          .toSet()
          .toList();
      final nameByActor = <String, String>{};
      if (actorIds.isNotEmpty) {
        try {
          final profs = List<Map<String, dynamic>>.from(
              await _db.from('profiles')
                  .select('id,name')
                  .inFilter('id', actorIds) as List);
          for (final p in profs) {
            final id = p['id'] as String?;
            final name = p['name'] as String?;
            if (id != null && name != null) nameByActor[id] = name;
          }
        } catch (_) {}
      }

      for (final r in rows) {
        final id = r['id']?.toString();
        if (id == null) continue;
        await HiveBoxes.activityLogsBox.put(id, {
          ...r,
          '_actor_name': nameByActor[r['actor_id'] as String?],
        });
      }
      debugPrint('[DB] syncActivityLogs: $shopId (${rows.length} logs)');
      _notify('activity_logs', shopId);
    } catch (e) {
      debugPrint('[DB] syncActivityLogs ERROR: $e');
    }
  }

  /// Lire les logs d'une boutique depuis Hive, triés du plus récent au plus ancien.
  static List<Map<String, dynamic>> getActivityLogsForShop(String shopId) {
    try {
      if (!Hive.isBoxOpen(HiveBoxes.activityLogs)) return [];
      final list = HiveBoxes.activityLogsBox.values
          .map((m) => Map<String, dynamic>.from(m))
          .where((m) => m['shop_id']?.toString() == shopId)
          .toList();
      list.sort((a, b) {
        final da = DateTime.tryParse(a['created_at']?.toString() ?? '')
            ?? DateTime(1970);
        final db = DateTime.tryParse(b['created_at']?.toString() ?? '')
            ?? DateTime(1970);
        return db.compareTo(da);
      });
      return list;
    } catch (_) {
      return [];
    }
  }

  /// Purger tous les logs d'une boutique via RPC Supabase, puis vider le
  /// cache Hive local pour cette boutique. Retourne le nombre de lignes
  /// supprimées côté serveur. L'appelant doit avoir été ré-authentifié
  /// (le dialogue UI s'en charge via re-auth mot de passe).
  static Future<int> purgeShopActivityLogs(String shopId) async {
    final result = await _db.rpc(
        'purge_shop_activity_logs', params: {'p_shop_id': shopId});
    // Vider le cache Hive local pour cette boutique
    if (Hive.isBoxOpen(HiveBoxes.activityLogs)) {
      final keys = HiveBoxes.activityLogsBox.keys.where((k) {
        final raw = HiveBoxes.activityLogsBox.get(k);
        return raw is Map && raw['shop_id']?.toString() == shopId;
      }).toList();
      for (final k in keys) {
        await HiveBoxes.activityLogsBox.delete(k);
      }
    }
    _notify('activity_logs', shopId);
    return (result as num?)?.toInt() ?? 0;
  }

  /// Purger tous les logs de la plateforme (super admin). Retourne le nombre
  /// supprimé serveur. Vide aussi le cache Hive local complet.
  static Future<int> purgeAllActivityLogs() async {
    final result = await _db.rpc('purge_all_activity_logs');
    if (Hive.isBoxOpen(HiveBoxes.activityLogs)) {
      await HiveBoxes.activityLogsBox.clear();
    }
    _notify('activity_logs', '_all');
    return (result as num?)?.toInt() ?? 0;
  }

  /// Callback realtime : ligne `activity_logs` INSERT → ajouter à Hive +
  /// résoudre le nom d'acteur (best-effort), puis notifier les listeners.
  Future<void> _onActivityLogChange(
      PostgresChangePayload p, String shopId) async {
    try {
      if (p.eventType != PostgresChangeEvent.insert) return;
      final r = Map<String, dynamic>.from(p.newRecord);
      final id = r['id']?.toString();
      if (id == null) return;
      String? actorName;
      final actorId = r['actor_id'] as String?;
      if (actorId != null) {
        try {
          final prof = await _db.from('profiles')
              .select('name').eq('id', actorId).maybeSingle();
          actorName = (prof?['name']) as String?;
        } catch (_) {}
      }
      await HiveBoxes.activityLogsBox.put(id, {
        ...r,
        '_actor_name': actorName,
      });
      _notify('activity_logs', shopId);
    } catch (e) {
      debugPrint('[DB] onActivityLogChange err: $e');
    }
  }

  // ══ EXPENSES (dépenses opérationnelles) ═══════════════════════════
  // Cache offline-first + realtime. Même pattern que activity_logs :
  // lectures depuis Hive, sync background complète, push Supabase via
  // l'offline-queue pour que les créations hors ligne soient conservées.

  /// Sauver ou mettre à jour une dépense (Hive immédiat + Supabase en queue).
  static Future<void> saveExpense(Expense e) async {
    if (!Hive.isBoxOpen(HiveBoxes.expenses)) return;
    final map = _expenseToMap(e);
    await HiveBoxes.expensesBox.put(e.id, map);
    _notify('expenses', e.shopId);
    _bgWrite({'table': 'expenses', 'op': 'upsert', 'data': _expenseToSupabase(e)});
  }

  /// Supprimer une dépense (Hive + Supabase).
  static Future<void> deleteExpense(String id, String shopId) async {
    await HiveBoxes.expensesBox.delete(id);
    _notify('expenses', shopId);
    _bgWrite({'table': 'expenses', 'op': 'delete',
      'col': 'id', 'val': id, 'data': {}});
  }

  /// Lire les dépenses d'une boutique, triées du plus récent paidAt au plus ancien.
  static List<Expense> getExpensesForShop(String shopId) {
    try {
      if (!Hive.isBoxOpen(HiveBoxes.expenses)) return [];
      final list = HiveBoxes.expensesBox.values
          .map((m) => _expenseFromMap(Map<String, dynamic>.from(m)))
          .where((e) => e.shopId == shopId)
          .toList();
      list.sort((a, b) => b.paidAt.compareTo(a.paidAt));
      return list;
    } catch (_) { return []; }
  }

  /// Pull Supabase → Hive. À appeler au montage de la page Dépenses et au
  /// retour en ligne (déjà intégré à _onNetworkRestored).
  static Future<void> syncExpenses(String shopId) async {
    try {
      if (!Hive.isBoxOpen(HiveBoxes.expenses)) return;
      final session = _db.auth.currentSession;
      if (session == null) return;
      final rows = await _db.from('expenses')
          .select()
          .eq('shop_id', shopId)
          .order('paid_at', ascending: false)
          .limit(500)
          .timeout(const Duration(seconds: 10));
      final list = rows as List;
      final remoteIds = <String>{};
      for (final row in list) {
        final id = row['id']?.toString();
        if (id == null) continue;
        remoteIds.add(id);
        await HiveBoxes.expensesBox.put(id, _mapFromSupabase(row));
      }
      // Diff purge : supprimer les dépenses locales de ce shop
      // qui n'existent plus distant (reset / suppression depuis autre appareil).
      final staleKeys = <dynamic>[];
      for (final key in HiveBoxes.expensesBox.keys) {
        final raw = HiveBoxes.expensesBox.get(key);
        if (raw is! Map) continue;
        if (raw['shop_id']?.toString() != shopId) continue;
        if (!remoteIds.contains(key.toString())) staleKeys.add(key);
      }
      for (final k in staleKeys) {
        await HiveBoxes.expensesBox.delete(k);
      }
      debugPrint('[DB] syncExpenses: $shopId '
          '(${list.length} remote, ${staleKeys.length} purgés)');
      _notify('expenses', shopId);
    } catch (e) {
      debugPrint('[DB] syncExpenses ERROR: $e');
    }
  }

  // ══ SYNC GÉNÉRIQUE (inventaire étendu) ════════════════════════════
  // Pull passthrough pour les tables où le format Supabase est directement
  // compatible avec le format Hive (suppliers, incidents, stock_movements,
  // receptions, purchase_orders, stock_arrivals). Aucune conversion —
  // chaque ligne est écrite telle quelle dans la box Hive par son `id`.

  /// Pull toutes les lignes d'une table pour une boutique et les écrit dans
  /// la box Hive correspondante. **Diff sync** : les lignes Hive de cette
  /// boutique qui ne sont plus présentes côté Supabase sont supprimées.
  /// Essentiel pour propager un reset fait depuis un autre appareil.
  static Future<void> _syncTablePassthrough({
    required String tableName,
    required String shopId,
    required Box<Map> box,
    String shopIdColumn = 'shop_id',
    String orderBy = 'created_at',
    int limit = 500,
  }) async {
    try {
      if (!box.isOpen) return;
      final session = _db.auth.currentSession;
      if (session == null) return;
      final rows = await _db.from(tableName)
          .select()
          .eq(shopIdColumn, shopId)
          .order(orderBy, ascending: false)
          .limit(limit)
          .timeout(const Duration(seconds: 10));
      final list = rows as List;
      final remoteIds = <String>{};
      for (final row in list) {
        final id = row['id']?.toString();
        if (id == null) continue;
        remoteIds.add(id);
        await box.put(id, Map<String, dynamic>.from(row));
      }
      // Purge : supprimer les lignes Hive de ce shop absentes distant.
      final staleKeys = <dynamic>[];
      for (final key in box.keys) {
        final raw = box.get(key);
        if (raw is! Map) continue;
        if (raw[shopIdColumn]?.toString() != shopId) continue;
        if (!remoteIds.contains(key.toString())) staleKeys.add(key);
      }
      for (final k in staleKeys) {
        await box.delete(k);
      }
      if (staleKeys.isNotEmpty) {
        debugPrint('[DB] sync $tableName: purge ${staleKeys.length} stale');
      }
      debugPrint('[DB] sync $tableName: $shopId '
          '(${list.length} remote, ${staleKeys.length} purgés)');
      _notify(tableName, shopId);
    } catch (e) {
      debugPrint('[DB] sync $tableName ERROR: $e');
    }
  }

  /// Callback realtime passthrough — applique INSERT/UPDATE/DELETE sur la
  /// box Hive correspondante dès qu'un changement arrive d'un autre appareil.
  Future<void> _onTablePassthroughChange(
      PostgresChangePayload p,
      Box<Map> box,
      String tableName,
      String shopId) async {
    try {
      switch (p.eventType) {
        case PostgresChangeEvent.insert:
        case PostgresChangeEvent.update:
          final id = p.newRecord['id']?.toString();
          if (id == null) return;
          await box.put(id, Map<String, dynamic>.from(p.newRecord));
        case PostgresChangeEvent.delete:
          final id = p.oldRecord['id']?.toString();
          if (id != null) await box.delete(id);
        default: break;
      }
      _notify(tableName, shopId);
    } catch (e) {
      debugPrint('[DB] on${tableName}Change err: $e');
    }
  }

  static Future<void> syncSuppliers(String shopId) =>
      _syncTablePassthrough(tableName: 'suppliers',
          shopId: shopId, box: HiveBoxes.suppliersBox);
  static Future<void> syncIncidents(String shopId) =>
      _syncTablePassthrough(tableName: 'incidents',
          shopId: shopId, box: HiveBoxes.incidentsBox);
  static Future<void> syncStockMovements(String shopId) =>
      _syncTablePassthrough(tableName: 'stock_movements',
          shopId: shopId, box: HiveBoxes.stockMovementsBox);
  static Future<void> syncReceptions(String shopId) =>
      _syncTablePassthrough(tableName: 'receptions',
          shopId: shopId, box: HiveBoxes.receptionsBox);
  static Future<void> syncPurchaseOrders(String shopId) =>
      _syncTablePassthrough(tableName: 'purchase_orders',
          shopId: shopId, box: HiveBoxes.purchaseOrdersBox);
  static Future<void> syncStockArrivals(String shopId) =>
      _syncTablePassthrough(tableName: 'stock_arrivals',
          shopId: shopId, box: HiveBoxes.stockArrivalsBox);
  /// Sync des transferts de commandes vers livreurs/partenaires (hotfix_049).
  /// Utilisé par le filtre dashboard / commandes / finances pour scoper aux
  /// commandes assignées à un partenaire spécifique.
  static Future<void> syncDeliveryTransfers(String shopId) =>
      _syncTablePassthrough(tableName: 'delivery_transfers',
          shopId: shopId, box: HiveBoxes.deliveryTransfersBox);
  /// Sync du livre de comptes partenaires (hotfix_062). Format Supabase
  /// directement compatible avec Hive — passthrough.
  static Future<void> syncPartnerLedger(String shopId) =>
      _syncTablePassthrough(tableName: 'partner_ledger_entries',
          shopId: shopId, box: HiveBoxes.partnerLedgerBox);

  /// Callback realtime pour orders. Reprend le format de `syncOrders` :
  /// inclut `fees` et `completed_at` pour éviter l'écrasement de ces
  /// colonnes sur le push distant.
  Future<void> _onOrderChange(
      PostgresChangePayload p, String shopId) async {
    try {
      switch (p.eventType) {
        case PostgresChangeEvent.insert:
        case PostgresChangeEvent.update:
          final id = p.newRecord['id']?.toString();
          if (id == null) return;
          final row = p.newRecord;
          // Idem syncOrders : conserver TOUS les champs livraison/expédition
          // pour préserver le snapshot de localisation côté Hive (sinon les
          // updates realtime effacent le delivery_location_id et la commande
          // « remonte » dans la boutique de base).
          final hiveMap = <String, dynamic>{
            'id':             id,
            'shop_id':        row['shop_id'],
            'status':         row['status'] ?? 'scheduled',
            'discount_amount': row['discount_amount'] ?? 0,
            'tax_rate':       row['tax_rate'] ?? 0,
            'payment_method': row['payment_method'] ?? 'cash',
            'client_id':      row['client_id'],
            'client_name':    row['client_name'],
            'client_phone':   row['client_phone'],
            'notes':          row['notes'],
            'scheduled_at':   row['scheduled_at'],
            'created_at':     row['created_at'],
            'completed_at':   row['completed_at'],
            'delivery_mode':        row['delivery_mode'],
            'delivery_location_id': row['delivery_location_id'],
            'delivery_person_name': row['delivery_person_name'],
            'delivery_city':        row['delivery_city'],
            'delivery_address':     row['delivery_address'],
            'shipment_city':        row['shipment_city'],
            'shipment_agency':      row['shipment_agency'],
            'shipment_handler':     row['shipment_handler'],
            'cancellation_reason':  row['cancellation_reason'],
            'reschedule_reason':    row['reschedule_reason'],
            'created_by_user_id':   row['created_by_user_id'],
            'items':          row['items'] ?? [],
            'fees':           row['fees'] ?? [],
          };
          await HiveBoxes.ordersBox.put(id, hiveMap);
          _emitOrderNotification(p, shopId, id, row);
        case PostgresChangeEvent.delete:
          final id = p.oldRecord['id']?.toString();
          if (id != null) await HiveBoxes.ordersBox.delete(id);
        default: break;
      }
      _notify('orders', shopId);
    } catch (e) {
      debugPrint('[DB] onOrderChange err: $e');
    }
  }

  /// Émet une notification in-app pour les évènements de commande pertinents
  /// (nouvelle commande / completed / cancelled / rejected). Filtré au niveau
  /// `NotificationService.enabledForCurrentUser` (admins + owners).
  void _emitOrderNotification(PostgresChangePayload p, String shopId,
      String id, Map<String, dynamic> row) {
    if (!NotificationService.enabledForCurrentUser.value) return;
    // Stock et orders restent réservés aux admins/owners — pas de spam
    // sur la cloche d'un vendeur qui ne peut rien faire avec.
    if (!_isAdminOrOwner(shopId)) return;
    final status = (row['status'] as String?) ?? 'scheduled';
    final clientName = (row['client_name'] as String?)?.trim() ?? '';
    final amount = ((row['amount_total'] ?? row['total'] ?? 0) as num)
        .toStringAsFixed(0);
    final shortId = id.length > 6 ? id.substring(0, 6).toUpperCase() : id;

    if (p.eventType == PostgresChangeEvent.insert) {
      // `source` (cf. hotfix_047) : permet d'afficher un badge canal
      // (Web / WhatsApp) dans le panel cloche.
      final src = (row['source'] as String?) ?? 'pos';
      NotificationService.notify(
        kind:    NotifKind.orderNew,
        title:   src == 'web' ? 'Nouvelle commande web' : 'Nouvelle commande',
        message: 'Commande #$shortId · $amount XAF',
        shopId:   shopId,
        targetId: id,
        source:   src,
      );
      return;
    }
    if (p.eventType == PostgresChangeEvent.update) {
      // Ne notifier que si le status a changé.
      final oldStatus = (p.oldRecord['status'] as String?) ?? '';
      if (oldStatus == status) return;
      switch (status) {
        case 'completed':
          NotificationService.notify(
            kind:    NotifKind.orderCompleted,
            title:   'Commande terminée',
            message: '#$shortId · ${clientName.isEmpty ? '—' : clientName}',
            shopId:   shopId,
            targetId: id,
          );
          break;
        case 'cancelled':
          NotificationService.notify(
            kind:    NotifKind.orderCancelled,
            title:   'Commande annulée',
            message: '#$shortId · ${clientName.isEmpty ? '—' : clientName}',
            shopId:   shopId,
            targetId: id,
          );
          break;
        case 'rejected':
        case 'refused':
          NotificationService.notify(
            kind:    NotifKind.orderRejected,
            title:   'Commande rejetée',
            message: '#$shortId · ${clientName.isEmpty ? '—' : clientName}',
            shopId:   shopId,
            targetId: id,
          );
          break;
      }
    }
  }

  // ══ TICKETS — callbacks realtime + notifs cloche ══════════════════
  //
  // Logique de routage des notifs selon le rôle de l'utilisateur courant :
  //   * `ticketNew`        → admins/owners de la shop quand un membre
  //                          ouvre un ticket (current_level='admin').
  //   * `ticketEscalated`  → owner quand un ticket monte à 'owner' ;
  //                          super_admin quand il monte à 'super_admin'.
  //   * `ticketReply`      → toute personne « impliquée » dans le ticket
  //                          (auteur du ticket OU admin/owner de la shop)
  //                          sauf l'auteur du message lui-même.
  //
  // Le filtre `enabledForCurrentUser` continue de gater l'insertion. Les
  // ids déterministes côté `NotificationService` empêchent les doublons.

  Future<void> _onTicketChange(
      PostgresChangePayload p, String shopId) async {
    try {
      // Mise à jour cache Hive (read-through pour les widgets locaux).
      switch (p.eventType) {
        case PostgresChangeEvent.insert:
        case PostgresChangeEvent.update:
          final id = p.newRecord['id']?.toString();
          if (id == null) return;
          await HiveBoxes.shopTicketsBox.put(id,
              Map<String, dynamic>.from(p.newRecord));
        case PostgresChangeEvent.delete:
          final id = p.oldRecord['id']?.toString();
          if (id != null) await HiveBoxes.shopTicketsBox.delete(id);
        default: break;
      }
      _notify('shop_tickets', shopId);
      _emitTicketNotification(p, shopId);
    } catch (e) {
      debugPrint('[DB] onTicketChange err: $e');
    }
  }

  Future<void> _onTicketMessageChange(
      PostgresChangePayload p, String shopId) async {
    try {
      if (p.eventType != PostgresChangeEvent.insert) return;
      final row = p.newRecord;
      final id  = row['id']?.toString();
      final ticketId = row['ticket_id']?.toString();
      if (id == null || ticketId == null) return;
      // Vérifier que le ticket appartient bien au shop courant (ce canal).
      final raw = HiveBoxes.shopTicketsBox.get(ticketId);
      if (raw is! Map) return;
      final ticketShop = raw['shop_id']?.toString();
      if (ticketShop != shopId) return;
      // Cache Hive du message.
      await HiveBoxes.ticketMessagesBox.put(id,
          Map<String, dynamic>.from(row));
      _notify('shop_ticket_messages', shopId);
      _emitTicketReplyNotification(row, raw, shopId);
    } catch (e) {
      debugPrint('[DB] onTicketMessageChange err: $e');
    }
  }

  /// Émet `ticketNew` (sur INSERT) ou `ticketEscalated` (sur UPDATE quand
  /// `current_level` a changé), filtré au rôle de l'utilisateur courant.
  void _emitTicketNotification(PostgresChangePayload p, String shopId) {
    if (!NotificationService.enabledForCurrentUser.value) return;
    final myUid = _userId;
    if (myUid == null) return;

    final row     = p.newRecord;
    final id      = row['id']?.toString() ?? '';
    final subject = (row['subject'] as String?)?.trim() ?? 'Ticket';
    final level   = (row['current_level'] as String?) ?? 'admin';
    final opener  = (row['opened_by']     as String?) ?? '';

    // Le rôle est déterminé par les memberships locales — déjà synchronisées
    // au login. Owner peut être détecté soit par membership='owner' soit
    // via shops.owner_id.
    final myRole = _roleOf(shopId, myUid);
    final isOwner = myRole == 'owner'
        || LocalStorageService.getShop(shopId)?.ownerId == myUid;

    if (p.eventType == PostgresChangeEvent.insert) {
      // ticketNew — seuls admins/owners reçoivent ; le créateur ne se
      // notifie pas lui-même.
      if (opener == myUid) return;
      final isAdmin = myRole == 'admin' || isOwner;
      if (!isAdmin) return;
      NotificationService.notify(
        kind:     NotifKind.ticketNew,
        title:    'Nouveau ticket',
        message:  subject,
        shopId:   shopId,
        targetId: id,
      );
      return;
    }

    if (p.eventType == PostgresChangeEvent.update) {
      // Détection du saut de niveau via comparaison newRecord/oldRecord.
      final oldLevel = (p.oldRecord['current_level'] as String?) ?? '';
      if (oldLevel == level) return; // pas un changement de niveau
      // ticketEscalated — destinataire = porteur du nouveau niveau.
      if (level == 'owner' && isOwner) {
        NotificationService.notify(
          kind:     NotifKind.ticketEscalated,
          title:    'Ticket escaladé — propriétaire',
          message:  subject,
          shopId:   shopId,
          // targetId enrichi du level pour que chaque escalade donne
          // sa propre notif (le dédup ne fusionne pas owner vs super_admin).
          targetId: '${id}_owner',
        );
      } else if (level == 'super_admin') {
        // Le client local n'est pas forcément super_admin ; on émet
        // uniquement si c'est le cas (sinon l'utilisateur n'est pas le
        // bon destinataire de cette escalade).
        final isSuper = LocalStorageService.getCurrentUser()?.isSuperAdmin
            ?? false;
        if (!isSuper) return;
        NotificationService.notify(
          kind:     NotifKind.ticketEscalated,
          title:    'Ticket escaladé — support',
          message:  subject,
          shopId:   shopId,
          targetId: '${id}_super',
        );
      }
    }
  }

  /// Émet `ticketReply` au porteur courant du ticket sauf si c'est lui
  /// qui vient de répondre. « Porteur » = auteur du ticket OU admin/owner
  /// de la shop selon le `current_level`.
  void _emitTicketReplyNotification(
      Map<String, dynamic> messageRow,
      Map ticketRaw,
      String shopId) {
    if (!NotificationService.enabledForCurrentUser.value) return;
    final myUid = _userId;
    if (myUid == null) return;
    final author = messageRow['author_id']?.toString();
    if (author == myUid) return; // pas auto-notif

    final messageId = messageRow['id']?.toString() ?? '';
    final t = Map<String, dynamic>.from(ticketRaw);
    final subject = (t['subject'] as String?)?.trim() ?? 'Ticket';
    final level   = (t['current_level'] as String?) ?? 'admin';
    final opener  = (t['opened_by']     as String?) ?? '';

    final myRole = _roleOf(shopId, myUid);
    final isOwner = myRole == 'owner'
        || LocalStorageService.getShop(shopId)?.ownerId == myUid;
    final isAdmin = myRole == 'admin' || isOwner;
    final isSuper = LocalStorageService.getCurrentUser()?.isSuperAdmin
        ?? false;

    // Critère « impliqué » :
    //   - auteur du ticket (suit toujours), OU
    //   - rôle au-dessus du current_level (peut le traiter).
    final relevantByLevel = switch (level) {
      'admin'        => isAdmin,
      'owner'        => isOwner,
      'super_admin'  => isSuper,
      _              => false,
    };
    if (opener != myUid && !relevantByLevel) return;

    final body = (messageRow['body'] as String?) ?? '';
    final preview = body.length > 60 ? '${body.substring(0, 60)}…' : body;
    NotificationService.notify(
      kind:     NotifKind.ticketReply,
      title:    'Réponse — $subject',
      message:  preview.isEmpty ? subject : preview,
      shopId:   shopId,
      // targetId = messageId pour qu'un nouveau message ne fusionne pas
      // avec le précédent (chaque message = sa propre notif jusqu'à FIFO).
      targetId: messageId,
    );
  }

  /// Rôle local de [userId] sur [shopId] depuis le cache memberships.
  /// Retourne `null` si pas membre. La key Hive est `${userId}_$shopId`,
  /// la valeur contient un champ `role` ('admin'|'owner'|'user'|...).
  String? _roleOf(String shopId, String userId) {
    final raw = HiveBoxes.membershipsBox.get('${userId}_$shopId');
    if (raw is! Map) return null;
    return raw['role']?.toString();
  }

  /// Callback realtime pour la table clients.
  /// Insère/update/delete sur Hive dès qu'un autre appareil (ou le même)
  /// modifie un client sur Supabase. Sans ça, les clients créés depuis
  /// desktop n'apparaissaient sur Android qu'à l'ouverture manuelle de la
  /// page Clients (le seul appel existant à `syncClients`).
  Future<void> _onClientChange(
      PostgresChangePayload p, String shopId) async {
    try {
      switch (p.eventType) {
        case PostgresChangeEvent.insert:
        case PostgresChangeEvent.update:
          final id = p.newRecord['id']?.toString();
          if (id == null) return;
          final client = _clientFromSupabase(
              Map<String, dynamic>.from(p.newRecord));
          HiveBoxes.clientsBox.put(id, _clientToMap(client));
        case PostgresChangeEvent.delete:
          final id = p.oldRecord['id']?.toString();
          if (id != null) HiveBoxes.clientsBox.delete(id);
        default: break;
      }
      _notify('clients', shopId);
    } catch (e) {
      debugPrint('[DB] onClientChange err: $e');
    }
  }

  /// Callback realtime pour la table expenses.
  Future<void> _onExpenseChange(
      PostgresChangePayload p, String shopId) async {
    try {
      switch (p.eventType) {
        case PostgresChangeEvent.insert:
        case PostgresChangeEvent.update:
          final id = p.newRecord['id']?.toString();
          if (id == null) return;
          await HiveBoxes.expensesBox.put(id, _mapFromSupabase(p.newRecord));
        case PostgresChangeEvent.delete:
          final id = p.oldRecord['id']?.toString();
          if (id != null) await HiveBoxes.expensesBox.delete(id);
        default: break;
      }
      _notify('expenses', shopId);
    } catch (e) {
      debugPrint('[DB] onExpenseChange err: $e');
    }
  }

  // ── Sérialisation Expense ──────────────────────────────────────────
  static Map<String, dynamic> _expenseToMap(Expense e) => {
    'id':             e.id,
    'shop_id':        e.shopId,
    'amount':         e.amount,
    'category':       e.category.name,
    'label':          e.label,
    'paid_at':        e.paidAt.toUtc().toIso8601String(),
    'payment_method': e.paymentMethod.name,
    'receipt_url':    e.receiptUrl,
    'notes':          e.notes,
    'created_by':     e.createdBy,
    'created_at':     e.createdAt.toUtc().toIso8601String(),
  };

  static Map<String, dynamic> _expenseToSupabase(Expense e) =>
      _expenseToMap(e); // mêmes colonnes

  static Expense _expenseFromMap(Map<String, dynamic> m) => Expense(
    id:       m['id'] as String,
    shopId:   m['shop_id'] as String,
    amount:   (m['amount'] as num).toDouble(),
    category: ExpenseCategoryX.fromString(m['category'] as String?),
    label:    (m['label'] as String?) ?? '',
    paidAt:   DateTime.parse(m['paid_at'] as String).toLocal(),
    paymentMethod: PaymentMethod.values.firstWhere(
        (p) => p.name == m['payment_method'],
        orElse: () => PaymentMethod.cash),
    receiptUrl: m['receipt_url'] as String?,
    notes:      m['notes'] as String?,
    createdBy:  m['created_by']?.toString(),
    createdAt:  m['created_at'] != null
        ? DateTime.parse(m['created_at'] as String).toLocal()
        : DateTime.now(),
  );

  /// Convertit une ligne Supabase en map Hive (mêmes colonnes, conversion UUID).
  static Map<String, dynamic> _mapFromSupabase(Map<dynamic, dynamic> row) => {
    'id':             row['id']?.toString(),
    'shop_id':        row['shop_id'],
    'amount':         row['amount'],
    'category':       row['category'],
    'label':          row['label'],
    'paid_at':        row['paid_at'],
    'payment_method': row['payment_method'] ?? 'cash',
    'receipt_url':    row['receipt_url'],
    'notes':          row['notes'],
    'created_by':     row['created_by']?.toString(),
    'created_at':     row['created_at'],
  };

  /// Synchroniser les commandes depuis Supabase vers Hive (pull)
  static Future<void> syncOrders(String shopId) async {
    try {
      if (!Hive.isBoxOpen(HiveBoxes.orders)) return;

      final session = _db.auth.currentSession;
      if (session == null) {
        debugPrint('[DB] syncOrders: session null, skip');
        return;
      }

      debugPrint('[DB] syncOrders: pull depuis Supabase pour $shopId');
      final rows = await _db
          .from('orders')
          .select()
          .eq('shop_id', shopId)
          .order('created_at', ascending: false)
          .limit(200)
          .timeout(const Duration(seconds: 10));

      final rowList = rows as List;
      debugPrint('[DB] syncOrders: ${rowList.length} commandes reçues');

      final remoteIds = <String>{};
      for (final row in rowList) {
        final id = row['id']?.toString();
        if (id == null) continue;
        remoteIds.add(id);
        // Écrire dans Hive — format compatible avec getOrders().
        // IMPORTANT : inclure TOUS les champs livraison/expédition/audit
        // sinon la sync écrase localement le snapshot de localisation
        // (bug : la commande revient à la boutique de base après reload
        // car delivery_location_id n'était pas réinjecté).
        final hiveMap = <String, dynamic>{
          'id':             id,
          'shop_id':        row['shop_id'],
          'status':         row['status'] ?? 'scheduled',
          'discount_amount': row['discount_amount'] ?? 0,
          'tax_rate':       row['tax_rate'] ?? 0,
          'payment_method': row['payment_method'] ?? 'cash',
          'client_id':      row['client_id'],
          'client_name':    row['client_name'],
          'client_phone':   row['client_phone'],
          'notes':          row['notes'],
          'scheduled_at':   row['scheduled_at'],
          'created_at':     row['created_at'],
          'completed_at':   row['completed_at'],
          'delivery_mode':        row['delivery_mode'],
          'delivery_location_id': row['delivery_location_id'],
          'delivery_person_name': row['delivery_person_name'],
          'delivery_city':        row['delivery_city'],
          'delivery_address':     row['delivery_address'],
          'shipment_city':        row['shipment_city'],
          'shipment_agency':      row['shipment_agency'],
          'shipment_handler':     row['shipment_handler'],
          'cancellation_reason':  row['cancellation_reason'],
          'reschedule_reason':    row['reschedule_reason'],
          'created_by_user_id':   row['created_by_user_id'],
          'items':          row['items'] ?? [],
          'fees':           row['fees'] ?? [],
          'source':         row['source'] ?? 'pos',
        };
        await HiveBoxes.ordersBox.put(id, hiveMap);
      }
      // Diff purge : supprimer les commandes locales de ce shop
      // qui ne sont plus distantes.
      final staleKeys = <dynamic>[];
      for (final key in HiveBoxes.ordersBox.keys) {
        final raw = HiveBoxes.ordersBox.get(key);
        if (raw is! Map) continue;
        if (raw['shop_id']?.toString() != shopId) continue;
        if (!remoteIds.contains(key.toString())) staleKeys.add(key);
      }
      for (final k in staleKeys) {
        await HiveBoxes.ordersBox.delete(k);
      }
      debugPrint('[DB] syncOrders: ${rowList.length} remote, '
          '${staleKeys.length} purgés');
      _notify('orders', shopId);
    } catch (e) {
      final err = e.toString();
      if (err.contains('42P01') || err.contains('does not exist')) {
        final sql = getSqlForTable('orders');
        debugPrint('[DB] ⚠️ Table "orders" inexistante. SQL:\n$sql');
      } else {
        debugPrint('[DB] syncOrders ERROR: $e');
      }
    }
  }

  // ══ CATÉGORIES / MARQUES / UNITÉS ═════════════════════════════════

  static Future<void> saveCategory(String shopId, String name) async {
    final list = LocalStorageService.getCategories(shopId);
    final isNew = !list.contains(name);
    if (isNew) { list.add(name); await HiveBoxes.settingsBox.put('categories_$shopId', list); }
    _bgWrite({'table': 'categories', 'op': 'upsert',
      'data': {'shop_id': shopId, 'name': name},
      'onConflict': 'shop_id,name'});
    if (isNew) {
      await ActivityLogService.log(
        action: 'category_created', targetType: 'category',
        targetId: name, targetLabel: name, shopId: shopId,
      );
    }
  }

  static Future<void> deleteCategory(String shopId, String name) async {
    if (LocalStorageService.getProductsForShop(shopId).any((p) => p.categoryId == name))
      throw Exception('Impossible de supprimer "$name" : utilisée par des produits.');
    if (_i._isOnline) {
      final rows = await _db.from('products').select('id').eq('store_id', shopId).eq('category_id', name).limit(1);
      if ((rows as List).isNotEmpty) throw Exception('Impossible de supprimer "$name" : utilisée par des produits.');
    }
    final list = LocalStorageService.getCategories(shopId)..remove(name);
    await HiveBoxes.settingsBox.put('categories_$shopId', list);
    _bgWrite({'table': 'categories', 'op': 'delete', 'col': 'name', 'val': name, 'data': {'shop_id': shopId, 'name': name}});
    await ActivityLogService.log(
      action: 'category_deleted', targetType: 'category',
      targetId: name, targetLabel: name, shopId: shopId,
    );
  }

  static Future<void> renameCategory(String shopId, String oldName, String newName) async {
    await deleteCategory(shopId, oldName);
    await saveCategory(shopId, newName);
    int used = 0;
    for (final p in LocalStorageService.getProductsForShop(shopId)) {
      if (p.categoryId == oldName) {
        final u = p.copyWith(categoryId: newName);
        await HiveBoxes.productsBox.put(p.id!, _productToMap(u));
        _bgWrite({'table': 'products', 'op': 'upsert', 'data': _productToSupabase(u)});
        used++;
      }
    }
    await ActivityLogService.log(
      action: 'category_updated', targetType: 'category',
      targetId: newName, targetLabel: newName, shopId: shopId,
      details: {'old_name': oldName, if (used > 0) 'used_by': used},
    );
  }

  static Future<void> saveBrand(String shopId, String name) async {
    final list = LocalStorageService.getBrands(shopId);
    final isNew = !list.contains(name);
    if (isNew) { list.add(name); await HiveBoxes.settingsBox.put('brands_$shopId', list); }
    _bgWrite({'table': 'brands', 'op': 'upsert',
      'data': {'shop_id': shopId, 'name': name},
      'onConflict': 'shop_id,name'});
    if (isNew) {
      await ActivityLogService.log(
        action: 'brand_created', targetType: 'brand',
        targetId: name, targetLabel: name, shopId: shopId,
      );
    }
  }

  static Future<void> deleteBrand(String shopId, String name) async {
    if (LocalStorageService.getProductsForShop(shopId).any((p) => p.brand?.toLowerCase() == name.toLowerCase()))
      throw Exception('Impossible de supprimer "$name" : utilisée par des produits.');
    if (_i._isOnline) {
      final rows = await _db.from('products').select('id').eq('store_id', shopId).ilike('brand', name).limit(1);
      if ((rows as List).isNotEmpty) throw Exception('Impossible de supprimer "$name" : utilisée par des produits.');
    }
    final list = LocalStorageService.getBrands(shopId)..remove(name);
    await HiveBoxes.settingsBox.put('brands_$shopId', list);
    _bgWrite({'table': 'brands', 'op': 'delete', 'col': 'name', 'val': name, 'data': {'shop_id': shopId, 'name': name}});
    await ActivityLogService.log(
      action: 'brand_deleted', targetType: 'brand',
      targetId: name, targetLabel: name, shopId: shopId,
    );
  }

  static Future<void> renameBrand(String shopId, String old, String neo) async {
    await deleteBrand(shopId, old); await saveBrand(shopId, neo);
    await ActivityLogService.log(
      action: 'brand_updated', targetType: 'brand',
      targetId: neo, targetLabel: neo, shopId: shopId,
      details: {'old_name': old},
    );
  }

  static Future<void> saveUnit(String shopId, String name) async {
    final list = LocalStorageService.getUnits(shopId);
    final isNew = !list.contains(name);
    if (isNew) { list.add(name); await HiveBoxes.settingsBox.put('units_$shopId', list); }
    _bgWrite({'table': 'units', 'op': 'upsert',
      'data': {'shop_id': shopId, 'name': name},
      'onConflict': 'shop_id,name'});
    if (isNew) {
      await ActivityLogService.log(
        action: 'unit_created', targetType: 'unit',
        targetId: name, targetLabel: name, shopId: shopId,
      );
    }
  }

  static Future<void> deleteUnit(String shopId, String name) async {
    final list = LocalStorageService.getUnits(shopId)..remove(name);
    await HiveBoxes.settingsBox.put('units_$shopId', list);
    _bgWrite({'table': 'units', 'op': 'delete', 'col': 'name', 'val': name, 'data': {'shop_id': shopId, 'name': name}});
    await ActivityLogService.log(
      action: 'unit_deleted', targetType: 'unit',
      targetId: name, targetLabel: name, shopId: shopId,
    );
  }

  static Future<void> renameUnit(String shopId, String old, String neo) async {
    await deleteUnit(shopId, old); await saveUnit(shopId, neo);
    await ActivityLogService.log(
      action: 'unit_updated', targetType: 'unit',
      targetId: neo, targetLabel: neo, shopId: shopId,
      details: {'old_name': old},
    );
  }

  static Future<void> syncMetadata(String shopId) async {
    try {
      final cats   = await _db.from('categories').select('name').eq('shop_id', shopId);
      final brands = await _db.from('brands').select('name').eq('shop_id', shopId);
      final units  = await _db.from('units').select('name').eq('shop_id', shopId);
      final cl = (cats   as List).map((r) => r['name'] as String).toList();
      final bl = (brands as List).map((r) => r['name'] as String).toList();
      final ul = (units  as List).map((r) => r['name'] as String).toList();
      // Supabase est source de vérité → toujours écrire dans Hive
      await HiveBoxes.settingsBox.put('categories_$shopId', cl);
      await HiveBoxes.settingsBox.put('brands_$shopId', bl);
      await HiveBoxes.settingsBox.put('units_$shopId', ul);
    } catch (e) { debugPrint('[DB] syncMetadata: $e'); }
  }

  // ══ SYNC LOGIN ════════════════════════════════════════════════════

  static Future<void> syncOnLogin(String userId) async {
    try {
      final shops = await getMyShops();
      for (final s in shops) {
        await syncProducts(s.id);
        await syncMetadata(s.id);
        await syncOrders(s.id);
      }
      // Sync memberships → Hive (rôles de l'utilisateur dans ses boutiques)
      await syncMemberships(userId);
      // Sync plan → cache Hive (pour accès offline)
      await _cachePlanToHive(userId);
      await flushOfflineQueue();
      debugPrint('[DB] ✅ Sync login: ${shops.length} boutiques');
    } catch (e) {
      debugPrint('[DB] syncOnLogin: $e');
    }
  }


  // ══ RESET BOUTIQUE ════════════════════════════════════════════════

  /// Vider une boutique (produits, catégories, marques, unités, memberships)
  /// mais GARDER les coordonnées d'authentification de l'admin
  static Future<void> resetShopData(String shopId) async {
    // 1. Supprimer produits Hive
    final prodKeys = HiveBoxes.productsBox.keys
        .where((k) {
      final raw = HiveBoxes.productsBox.get(k);
      if (raw == null) return false;
      final m = Map<String, dynamic>.from(raw);
      return m['store_id'] == shopId;
    }).toList();
    for (final k in prodKeys) await HiveBoxes.productsBox.delete(k);

    // 2. Supprimer TOUTES les clés settings liées à cette boutique
    final shopKeys = HiveBoxes.settingsBox.keys
        .where((k) => k.toString().contains(shopId))
        .toList();
    for (final k in shopKeys) await HiveBoxes.settingsBox.delete(k);
    // Clés metadata explicites (au cas où le shopId n'est pas dans la clé)
    await HiveBoxes.settingsBox.delete('categories_$shopId');
    await HiveBoxes.settingsBox.delete('brands_$shopId');
    await HiveBoxes.settingsBox.delete('units_$shopId');
    await HiveBoxes.settingsBox.delete('members_$shopId');

    // 3. Supprimer les données cycle de vie produit liées à cette boutique
    Future<void> clearBoxByShop(dynamic box, String field) async {
      final keys = box.keys.where((k) {
        final m = box.get(k);
        return m is Map && m[field]?.toString() == shopId;
      }).toList();
      for (final k in keys) await box.delete(k);
    }
    await clearBoxByShop(HiveBoxes.suppliersBox, 'shop_id');
    await clearBoxByShop(HiveBoxes.receptionsBox, 'shop_id');
    await clearBoxByShop(HiveBoxes.incidentsBox, 'shop_id');
    await clearBoxByShop(HiveBoxes.stockMovementsBox, 'shop_id');
    await clearBoxByShop(HiveBoxes.purchaseOrdersBox, 'shop_id');
    await clearBoxByShop(HiveBoxes.stockArrivalsBox, 'shop_id');
    await clearBoxByShop(HiveBoxes.expensesBox, 'shop_id');
    // Clients utilise `store_id` (pas `shop_id`).
    await clearBoxByShop(HiveBoxes.clientsBox,   'store_id');
    await clearBoxByShop(HiveBoxes.ordersBox,    'shop_id');

    // 4. Supabase en arrière-plan
    if (_i._isOnline) {
      _executeOp({'table': 'products',       'op': 'delete', 'col': 'store_id', 'val': shopId, 'data': {}});
      _executeOp({'table': 'categories',     'op': 'delete', 'col': 'shop_id',  'val': shopId, 'data': {}});
      _executeOp({'table': 'brands',         'op': 'delete', 'col': 'shop_id',  'val': shopId, 'data': {}});
      _executeOp({'table': 'units',          'op': 'delete', 'col': 'shop_id',  'val': shopId, 'data': {}});
      _executeOp({'table': 'suppliers',      'op': 'delete', 'col': 'shop_id',  'val': shopId, 'data': {}});
      _executeOp({'table': 'incidents',      'op': 'delete', 'col': 'shop_id',  'val': shopId, 'data': {}});
      _executeOp({'table': 'stock_movements','op': 'delete', 'col': 'shop_id',  'val': shopId, 'data': {}});
      _executeOp({'table': 'receptions',     'op': 'delete', 'col': 'shop_id',  'val': shopId, 'data': {}});
      _executeOp({'table': 'purchase_orders','op': 'delete', 'col': 'shop_id',  'val': shopId, 'data': {}});
      _executeOp({'table': 'stock_arrivals', 'op': 'delete', 'col': 'shop_id',  'val': shopId, 'data': {}});
      _executeOp({'table': 'expenses',       'op': 'delete', 'col': 'shop_id',  'val': shopId, 'data': {}});
      _executeOp({'table': 'clients',        'op': 'delete', 'col': 'store_id', 'val': shopId, 'data': {}});
      _executeOp({'table': 'orders',         'op': 'delete', 'col': 'shop_id',  'val': shopId, 'data': {}});
    }
    _notify('products', shopId);
    _notify('clients',  shopId);
    _notify('orders',   shopId);
    _notify('expenses', shopId);
    debugPrint('[DB] ✅ Boutique réinitialisée: $shopId');
  }

  // ══ RESET BOUTIQUE — GARDER PRODUITS / CATEGORIES / MARQUES / UNITES ══

  /// One-shot : réinitialise une boutique en GARDANT
  /// produits, catégories, marques, unités et leurs stocks actuels.
  /// Supprime ventes, commandes, clients, fournisseurs, réceptions,
  /// incidents, mouvements de stock, bons de commande, arrivages,
  /// dépenses, logs d'activité, et tous les emplacements warehouse /
  /// partenaire de l'utilisateur (avec leurs StockLevels et transferts).
  /// Hive + Supabase. Le panier (cart_box) est vidé par sécurité.
  /// Nettoie les données Hive locales d'une boutique APRÈS qu'un reset
  /// remote a déjà eu lieu (typiquement via le RPC `reset_shop_data`).
  ///
  /// Périmètre : ventes, commandes, clients, fournisseurs, réceptions,
  /// incidents, mouvements stock, expenses, activity_logs, panier, et —
  /// crucial — partenaires/warehouses **owner-scoped** + leurs stock_levels
  /// et transferts. La location type='shop' est conservée (recréée par la
  /// migration Phase 1 au prochain démarrage si besoin).
  ///
  /// Conserve : produits, catégories, marques, unités, stock_locations
  /// type='shop' (la base d'inventaire).
  ///
  /// Utilisé par `_resetShop` (bouton réutilisable) pour aligner Hive
  /// immédiatement après le RPC, sans dépendre de la propagation realtime
  /// (qui peut être lente ou ne pas couvrir les delete partner-level).
  static Future<void> clearShopLocalData(String shopId) async {
    final shop = LocalStorageService.getShop(shopId);
    final ownerId = shop?.ownerId;

    Future<void> clearByShop(dynamic box, String field) async {
      final keys = box.keys.where((k) {
        final m = box.get(k);
        return m is Map && m[field]?.toString() == shopId;
      }).toList();
      for (final k in keys) {
        await box.delete(k);
      }
    }

    await clearByShop(HiveBoxes.salesBox,            'shop_id');
    await clearByShop(HiveBoxes.ordersBox,           'shop_id');
    await clearByShop(HiveBoxes.clientsBox,          'store_id');
    await clearByShop(HiveBoxes.suppliersBox,        'shop_id');
    await clearByShop(HiveBoxes.receptionsBox,       'shop_id');
    await clearByShop(HiveBoxes.incidentsBox,        'shop_id');
    await clearByShop(HiveBoxes.stockMovementsBox,   'shop_id');
    await clearByShop(HiveBoxes.purchaseOrdersBox,   'shop_id');
    await clearByShop(HiveBoxes.stockArrivalsBox,    'shop_id');
    await clearByShop(HiveBoxes.expensesBox,         'shop_id');
    await clearByShop(HiveBoxes.activityLogsBox,     'shop_id');
    await clearByShop(HiveBoxes.deliveryTransfersBox,'shop_id');

    // Panier global (pas filtrable par shop)
    await HiveBoxes.cartBox.clear();

    // Partenaires + warehouses du même owner (shop_id NULL par design,
    // donc pas attrapés par clearByShop). On garde la location type='shop'
    // — c'est la base de stock locale ré-utilisable.
    final shopLocId = _shopLocationId(shopId);
    final delLocIds = <String>{};
    if (ownerId != null && ownerId.isNotEmpty) {
      for (final k in HiveBoxes.stockLocationsBox.keys) {
        final raw = HiveBoxes.stockLocationsBox.get(k);
        if (raw is! Map) continue;
        final m = Map<String, dynamic>.from(raw);
        final locId = m['id']?.toString();
        if (locId == null || locId == shopLocId) continue;
        final type = m['type']?.toString();
        if (m['owner_id']?.toString() == ownerId
            && (type == 'partner' || type == 'warehouse')) {
          delLocIds.add(locId);
        }
      }
    }

    // stock_levels rattachés aux partenaires + ceux du shop (le RPC les
    // a déjà supprimés côté serveur, on aligne ici).
    final levelKeysToDelete = <dynamic>[];
    for (final k in HiveBoxes.stockLevelsBox.keys) {
      final raw = HiveBoxes.stockLevelsBox.get(k);
      if (raw is! Map) continue;
      final m = Map<String, dynamic>.from(raw);
      final locId = m['location_id']?.toString();
      if (delLocIds.contains(locId) || locId == shopLocId
          || m['shop_id']?.toString() == shopId) {
        levelKeysToDelete.add(k);
      }
    }
    for (final k in levelKeysToDelete) {
      await HiveBoxes.stockLevelsBox.delete(k);
    }

    // stock_transfers touchés par les locations supprimées
    final transferKeysToDelete = <dynamic>[];
    for (final k in HiveBoxes.stockTransfersBox.keys) {
      final raw = HiveBoxes.stockTransfersBox.get(k);
      if (raw is! Map) continue;
      final m = Map<String, dynamic>.from(raw);
      final from = m['from_location_id']?.toString();
      final to   = m['to_location_id']?.toString();
      if (delLocIds.contains(from) || delLocIds.contains(to)
          || from == shopLocId || to == shopLocId) {
        transferKeysToDelete.add(k);
      }
    }
    for (final k in transferKeysToDelete) {
      await HiveBoxes.stockTransfersBox.delete(k);
    }

    // Locations partenaires/warehouses elles-mêmes
    for (final k in delLocIds) {
      await HiveBoxes.stockLocationsBox.delete(k);
    }

    // Notifs UI : tous les listeners rebuild
    _notify('clients',         shopId);
    _notify('orders',          shopId);
    _notify('sales',           shopId);
    _notify('expenses',        shopId);
    _notify('stock_locations', shopId);
    _notify('stock_levels',    shopId);
    _notify('stock_transfers', shopId);
    _notify('activity_logs',   shopId);
    debugPrint('[DB] clearShopLocalData $shopId — '
        '${delLocIds.length} location(s) partenaire/warehouse supprimée(s)');
  }

  static Future<void> resetShopKeepProducts(String shopId) async {
    final userId = LocalStorageService.getCurrentUser()?.id ?? '';

    // 1. Vider boxes Hive filtrées par shop_id (ou store_id pour clients)
    Future<void> clearByShop(dynamic box, String field) async {
      final keys = box.keys.where((k) {
        final m = box.get(k);
        return m is Map && m[field]?.toString() == shopId;
      }).toList();
      for (final k in keys) {
        await box.delete(k);
      }
    }

    await clearByShop(HiveBoxes.salesBox,          'shop_id');
    await clearByShop(HiveBoxes.ordersBox,         'shop_id');
    await clearByShop(HiveBoxes.clientsBox,        'store_id');
    await clearByShop(HiveBoxes.suppliersBox,      'shop_id');
    await clearByShop(HiveBoxes.receptionsBox,     'shop_id');
    await clearByShop(HiveBoxes.incidentsBox,      'shop_id');
    await clearByShop(HiveBoxes.stockMovementsBox, 'shop_id');
    await clearByShop(HiveBoxes.purchaseOrdersBox, 'shop_id');
    await clearByShop(HiveBoxes.stockArrivalsBox,  'shop_id');
    await clearByShop(HiveBoxes.expensesBox,       'shop_id');
    await clearByShop(HiveBoxes.activityLogsBox,   'shop_id');

    // 2. Vider le panier (panier global, pas filtrable par shop)
    await HiveBoxes.cartBox.clear();

    // 3. Identifier warehouses + partners de l'utilisateur (à supprimer).
    //    On garde la StockLocation type=shop liée à shopId.
    final shopLocId = _shopLocationId(shopId);
    final delLocIds = <String>{};
    for (final k in HiveBoxes.stockLocationsBox.keys) {
      final raw = HiveBoxes.stockLocationsBox.get(k);
      if (raw is! Map) continue;
      final m = Map<String, dynamic>.from(raw);
      final locId = m['id']?.toString();
      final ownerIdLoc = m['owner_id']?.toString();
      final type = m['type']?.toString();
      if (locId == null || locId == shopLocId) continue;
      if (ownerIdLoc == userId &&
          (type == 'warehouse' || type == 'partner')) {
        delLocIds.add(locId);
      }
    }

    // 4. StockLevels rattachés à ces locations (pas ceux du shop)
    final levelKeysToDelete = <dynamic>[];
    for (final k in HiveBoxes.stockLevelsBox.keys) {
      final raw = HiveBoxes.stockLevelsBox.get(k);
      if (raw is! Map) continue;
      final m = Map<String, dynamic>.from(raw);
      if (delLocIds.contains(m['location_id']?.toString())) {
        levelKeysToDelete.add(k);
      }
    }

    // 5. Transferts touchés (from OU to fait partie des locations à supprimer)
    final transferKeysToDelete = <dynamic>[];
    for (final k in HiveBoxes.stockTransfersBox.keys) {
      final raw = HiveBoxes.stockTransfersBox.get(k);
      if (raw is! Map) continue;
      final m = Map<String, dynamic>.from(raw);
      final from = m['from_location_id']?.toString();
      final to   = m['to_location_id']?.toString();
      if (delLocIds.contains(from) || delLocIds.contains(to)) {
        transferKeysToDelete.add(k);
      }
    }

    for (final k in levelKeysToDelete) {
      await HiveBoxes.stockLevelsBox.delete(k);
    }
    for (final k in transferKeysToDelete) {
      await HiveBoxes.stockTransfersBox.delete(k);
    }
    for (final k in delLocIds) {
      await HiveBoxes.stockLocationsBox.delete(k);
    }

    // 6. Settings : tout sauf les caches métadata produits.
    final keepKeys = {
      'categories_$shopId',
      'brands_$shopId',
      'units_$shopId',
    };
    final settingsKeys = HiveBoxes.settingsBox.keys
        .where((k) {
          final s = k.toString();
          return s.contains(shopId) && !keepKeys.contains(s);
        })
        .toList();
    for (final k in settingsKeys) {
      await HiveBoxes.settingsBox.delete(k);
    }

    // 7. Supabase : purge serveur des mêmes tables.
    if (_i._isOnline) {
      Future<void> tryDelete(String table, String col, String val) async {
        try {
          await _db.from(table).delete().eq(col, val);
        } catch (e) {
          debugPrint('[DB] resetShopKeepProducts $table: $e');
          _enqueue({
            'table': table, 'op': 'delete',
            'col': col, 'val': val, 'data': {},
          });
        }
      }
      await tryDelete('sales',           'shop_id',  shopId);
      await tryDelete('orders',          'shop_id',  shopId);
      await tryDelete('clients',         'store_id', shopId);
      await tryDelete('suppliers',       'shop_id',  shopId);
      await tryDelete('receptions',      'shop_id',  shopId);
      await tryDelete('incidents',       'shop_id',  shopId);
      await tryDelete('stock_movements', 'shop_id',  shopId);
      await tryDelete('purchase_orders', 'shop_id',  shopId);
      await tryDelete('stock_arrivals',  'shop_id',  shopId);
      await tryDelete('expenses',        'shop_id',  shopId);
      await tryDelete('activity_logs',   'shop_id',  shopId);

      // Warehouses + partners → suppression par ID (pas filtrable par shop)
      for (final locId in delLocIds) {
        try {
          await _db.from('stock_levels')
              .delete().eq('location_id', locId);
          await _db.from('stock_transfers')
              .delete().or('from_location_id.eq.$locId,'
                           'to_location_id.eq.$locId');
          await _db.from('stock_locations')
              .delete().eq('id', locId);
        } catch (e) {
          debugPrint('[DB] resetShopKeepProducts loc $locId: $e');
          _enqueue({
            'table': 'stock_locations', 'op': 'delete',
            'col': 'id', 'val': locId, 'data': {},
          });
        }
      }
    } else {
      void enq(String table, String col, String val) =>
          _enqueue({
            'table': table, 'op': 'delete',
            'col': col, 'val': val, 'data': {},
          });
      enq('sales',           'shop_id',  shopId);
      enq('orders',          'shop_id',  shopId);
      enq('clients',         'store_id', shopId);
      enq('suppliers',       'shop_id',  shopId);
      enq('receptions',      'shop_id',  shopId);
      enq('incidents',       'shop_id',  shopId);
      enq('stock_movements', 'shop_id',  shopId);
      enq('purchase_orders', 'shop_id',  shopId);
      enq('stock_arrivals',  'shop_id',  shopId);
      enq('expenses',        'shop_id',  shopId);
      enq('activity_logs',   'shop_id',  shopId);
      for (final locId in delLocIds) {
        enq('stock_locations', 'id', locId);
      }
    }

    // 8. Notifs UI
    _notify('clients',         shopId);
    _notify('orders',          shopId);
    _notify('sales',           shopId);
    _notify('expenses',        shopId);
    _notify('stock_locations', shopId);
    _notify('stock_levels',    shopId);
    _notify('stock_transfers', shopId);
    _notify('activity_logs',   shopId);
    debugPrint(
        '[DB] ✅ Boutique réinitialisée (produits gardés): $shopId '
        '— ${delLocIds.length} emplacement(s) supprimé(s)');
    await ActivityLogService.log(
      action:      'shop_reset_keep_products',
      targetType:  'shop',
      targetId:    shopId,
      targetLabel: LocalStorageService.getShop(shopId)?.name,
      shopId:      shopId,
      details: {
        'locations': delLocIds.length,
      },
    );
  }

  // ══ SUPPRIMER BOUTIQUE ════════════════════════════════════════════

  static Future<void> deleteShop(String shopId) async {
    // Pas de garde "stock > 0" ici : la saisie du nom exact dans le dialogue
    // de confirmation suffit comme preuve d'intention. La perte du stock est
    // une conséquence interne à la boutique supprimée — annoncée à
    // l'utilisateur via shopDeleteConseqAll — pas un dysfonctionnement
    // d'une autre entité liée.
    final shopName     = LocalStorageService.getShop(shopId)?.name;
    final products     = LocalStorageService.getProductsForShop(shopId);
    final productsCount = products.length;

    // Reset données d'abord
    await resetShopData(shopId);

    // Purger la StockLocation type=shop associée + ses StockLevels
    // (créés par la migration Phase 1). Sans ça, l'onglet Emplacements
    // continuerait d'afficher la boutique fantôme.
    final shopLocId = _shopLocationId(shopId);
    final levelKeys = HiveBoxes.stockLevelsBox.values
        .where((raw) {
          final m = Map<String, dynamic>.from(raw);
          return m['location_id'] == shopLocId;
        })
        .map((raw) =>
            (Map<String, dynamic>.from(raw))['id'] as String?)
        .whereType<String>()
        .toList();
    for (final k in levelKeys) {
      await HiveBoxes.stockLevelsBox.delete(k);
    }
    await HiveBoxes.stockLocationsBox.delete(shopLocId);

    // Supprimer la boutique et ses memberships de Hive
    await HiveBoxes.shopsBox.delete(shopId);
    final memKeys = HiveBoxes.membershipsBox.keys
        .where((k) => k.toString().contains('_$shopId')).toList();
    for (final k in memKeys) await HiveBoxes.membershipsBox.delete(k);

    // Supabase : la cascade ON DELETE CASCADE sur stock_locations.shop_id
    // + stock_levels.location_id supprime tout côté serveur. On envoie aussi
    // un delete explicite des locations pour les cas sans cascade.
    if (_i._isOnline) {
      try {
        await _db.from('stock_levels').delete().eq('location_id', shopLocId);
        await _db.from('stock_locations').delete().eq('shop_id', shopId);
        await _db.from('shop_memberships').delete().eq('shop_id', shopId);
        await _db.from('shops').delete().eq('id', shopId);
      } catch (e) {
        debugPrint('[DB] deleteShop Supabase: $e');
        _enqueue({'table': 'shops', 'op': 'delete', 'col': 'id', 'val': shopId, 'data': {}});
      }
    } else {
      _enqueue({'table': 'stock_locations', 'op': 'delete',
        'col': 'shop_id', 'val': shopId, 'data': {}});
      _enqueue({'table': 'shops', 'op': 'delete',
        'col': 'id', 'val': shopId, 'data': {}});
    }

    // Effacer aussi le flag de migration v1 pour cette boutique :
    // si une boutique avec le même id est recréée plus tard (rare),
    // la migration repartira proprement.
    await HiveBoxes.settingsBox.delete('$_kMigrationV1FlagPrefix$shopId');

    _notify('stock_locations', shopId);
    _notify('shops', shopId);
    debugPrint('[DB] ✅ Boutique supprimée: $shopId');
    await ActivityLogService.log(
      action:      'shop_deleted',
      targetType:  'shop',
      targetId:    shopId,
      targetLabel: shopName,
      shopId:      shopId,
      details: {
        if (productsCount > 0) 'products_count': productsCount,
      },
    );
  }

  // ══ COPIER PRODUIT VERS AUTRE BOUTIQUE ════════════════════════════

  static Future<Product> copyProductToShop(Product source, String targetShopId) async {
    final ts      = DateTime.now().microsecondsSinceEpoch;
    final newId   = 'prod_${ts}_copy';

    final copied = Product(
      id:            newId,
      storeId:       targetShopId,
      categoryId:    source.categoryId,
      brand:         source.brand,
      name:          source.name,
      description:   source.description,
      barcode:       null, // reset pour éviter doublons
      sku:           null, // reset pour éviter doublons
      priceBuy:      source.priceBuy,
      customsFee:    source.customsFee,
      priceSellPos:  source.priceSellPos,
      priceSellWeb:  source.priceSellWeb,
      taxRate:       source.taxRate,
      stockQty:      source.stockQty,
      stockMinAlert: source.stockMinAlert,
      isActive:      source.isActive,
      isVisibleWeb:  false,
      imageUrl:      source.imageUrl,
      rating:        source.rating,
      variants:      source.variants.asMap().entries.map((e) =>
          ProductVariant(
            id:                 'var_${ts}_${e.key}',
            name:               e.value.name,
            sku:                null,
            barcode:            null,
            supplier:           e.value.supplier,
            supplierRef:        e.value.supplierRef,
            priceBuy:           e.value.priceBuy,
            priceSellPos:       e.value.priceSellPos,
            priceSellWeb:       e.value.priceSellWeb,
            stockAvailable:     e.value.stockAvailable,
            stockPhysical:      e.value.stockPhysical,
            stockOrdered:       e.value.stockOrdered,
            stockBlocked:       e.value.stockBlocked,
            stockMinAlert:      e.value.stockMinAlert,
            imageUrl:           e.value.imageUrl,
            secondaryImageUrls: List.from(e.value.secondaryImageUrls),
            isMain:             e.value.isMain,
            promoEnabled:       false,
          )
      ).toList(),
      expenses: List.from(source.expenses),
    );

    await saveProduct(copied);
    debugPrint('[DB] ✅ Produit copié: ${source.name} → $targetShopId');

    // Audit bidirectionnel : log dans la boutique SOURCE et la boutique
    // DESTINATION pour que les deux historiques voient l'opération.
    final sourceShopId = source.storeId;
    final sourceShopName = sourceShopId != null
        ? LocalStorageService.getShop(sourceShopId)?.name : null;
    final targetShopName = LocalStorageService.getShop(targetShopId)?.name;
    final commonCopyDetails = <String, dynamic>{
      'product':     source.name,
      'from_shop':   sourceShopName,
      'to_shop':     targetShopName,
      if ((source.sku ?? '').isNotEmpty) 'sku': source.sku,
      if (source.variants.isNotEmpty)
        'variant_count': source.variants.length,
    };
    if (sourceShopId != null) {
      await ActivityLogService.log(
        action:      'product_copied_out',
        targetType:  'product',
        targetId:    source.id,
        targetLabel: source.name,
        shopId:      sourceShopId,
        details:     {...commonCopyDetails, 'direction': 'out'},
      );
    }
    if (sourceShopId != targetShopId) {
      await ActivityLogService.log(
        action:      'product_copied_in',
        targetType:  'product',
        targetId:    newId,
        targetLabel: copied.name,
        shopId:      targetShopId,
        details:     {...commonCopyDetails, 'direction': 'in'},
      );
    }

    return copied;
  }

  // ══ GESTION UTILISATEURS ══════════════════════════════════════════

  /// Charger les membres d'une boutique depuis Supabase.
  ///
  /// Utilise la RPC `list_shop_employees` (cf. hotfix_018) qui fait le JOIN
  /// `shop_memberships` × `profiles` côté serveur via SECURITY DEFINER.
  /// Évite l'erreur PostgREST "Could not find a relationship between
  /// shop_memberships and profiles in the schema cache" (cas où la FK
  /// déclarative manque).
  ///
  /// Le shape de retour est massé pour rester compatible avec les callers
  /// existants (champ `profiles` embarqué).
  static Future<List<Map<String, dynamic>>> getShopMembers(String shopId) async {
    try {
      if (!await isOnline()) return _getShopMembersLocal(shopId);
      final rows = await _db.rpc(
        'list_shop_employees',
        params: {'p_shop_id': shopId},
      );
      final list = (rows as List).map((r) {
        final m = Map<String, dynamic>.from(r as Map);
        return <String, dynamic>{
          'user_id':   m['user_id'],
          'role':      m['role'],
          'joined_at': m['created_at'],
          'status':    m['status'],
          'is_owner':  m['is_owner'],
          // Sous-objet `profiles` reconstruit pour rétrocompat callers UI.
          'profiles': <String, dynamic>{
            'id':         m['user_id'],
            'name':       m['full_name'],
            'email':      m['email'],
            'phone':      null,
            'avatar_url': null,
          },
        };
      }).toList();
      await HiveBoxes.settingsBox.put('members_$shopId', list);
      return list;
    } catch (e) {
      debugPrint('[DB] getShopMembers: $e');
      return _getShopMembersLocal(shopId);
    }
  }

  static List<Map<String, dynamic>> _getShopMembersLocal(String shopId) {
    final raw = HiveBoxes.settingsBox.get('members_$shopId');
    if (raw == null) return [];
    return (raw as List).map((m) => Map<String, dynamic>.from(m as Map)).toList();
  }

  /// Changer le rôle d'un membre
  static Future<void> updateMemberRole(
      String shopId, String userId, UserRole role) async {
    // Hive local
    final cached = _getShopMembersLocal(shopId);
    for (final m in cached) {
      if (m['user_id'] == userId) m['role'] = role.key;
    }
    await HiveBoxes.settingsBox.put('members_$shopId', cached);

    // Supabase
    _bgWrite({
      'table': 'shop_memberships',
      'op':    'upsert',
      'data':  {'shop_id': shopId, 'user_id': userId, 'role': role.key},
    });
    debugPrint('[DB] ✅ Rôle mis à jour: $userId → ${role.key}');
  }

  /// Supprimer un membre d'une boutique
  static Future<void> removeMember(String shopId, String userId) async {
    final cached = _getShopMembersLocal(shopId)
        .where((m) => m['user_id'] != userId).toList();
    await HiveBoxes.settingsBox.put('members_$shopId', cached);

    if (_i._isOnline) {
      try {
        await _db.from('shop_memberships')
            .delete()
            .eq('shop_id', shopId)
            .eq('user_id', userId);
      } catch (e) {
        debugPrint('[DB] removeMember: $e');
      }
    }
    debugPrint('[DB] ✅ Membre retiré: $userId');
  }

  /// Inviter un utilisateur par email.
  /// Si l'email existe dans profiles → ajout immédiat du membership.
  /// Sinon → crée une pending_invitation + envoie un magic-link.
  static Future<InviteResult> inviteMember(
      String shopId, String email, UserRole role) async {
    if (!await isOnline()) throw Exception('Connexion requise pour inviter un membre');

    final normalizedEmail = email.trim().toLowerCase();

    // 1. Essayer de retrouver un profil existant
    final profile = await _db
        .from('profiles')
        .select('id, name, email')
        .eq('email', normalizedEmail)
        .maybeSingle();

    if (profile != null) {
      final userId = profile['id'] as String;
      final existing = await _db
          .from('shop_memberships')
          .select('id')
          .eq('shop_id', shopId)
          .eq('user_id', userId)
          .maybeSingle();
      if (existing != null) {
        throw Exception("${profile['name']} est déjà membre de cette boutique.");
      }
      await _db.from('shop_memberships').insert({
        'shop_id': shopId, 'user_id': userId, 'role': role.key,
      });
      await getShopMembers(shopId);
      debugPrint('[DB] ✅ Membre ajouté: $normalizedEmail → ${role.key}');
      return InviteResult(
        outcome:     InviteOutcome.addedImmediately,
        email:       normalizedEmail,
        invitedName: profile['name'] as String?,
      );
    }

    // 2. Email inconnu → créer une invitation et envoyer un magic-link
    final rpcResult = await _db.rpc('create_shop_invitation', params: {
      'p_shop_id': shopId,
      'p_email':   normalizedEmail,
      'p_role':    role.key,
    });
    final token = (rpcResult as Map)['token'] as String;

    final redirectUrl =
        '${SupabaseConfig.acceptInviteBaseUrl}?token=${Uri.encodeComponent(token)}';
    await _db.auth.signInWithOtp(
      email:            normalizedEmail,
      emailRedirectTo:  redirectUrl,
      shouldCreateUser: true,
    );

    debugPrint('[DB] ✉️ Invitation envoyée: $normalizedEmail → ${role.key}');
    return InviteResult(
      outcome: InviteOutcome.invitationSent,
      email:   normalizedEmail,
    );
  }

  /// Liste les invitations en attente (non expirées) pour une boutique.
  static Future<List<Map<String, dynamic>>> getPendingInvitations(
      String shopId) async {
    if (!await isOnline()) return [];
    try {
      final rows = await _db
          .from('pending_invitations')
          .select('id, email, role, invited_by, created_at, expires_at')
          .eq('shop_id', shopId)
          .gt('expires_at', DateTime.now().toUtc().toIso8601String())
          .order('created_at', ascending: false);
      return List<Map<String, dynamic>>.from(rows as List);
    } catch (e) {
      debugPrint('[DB] getPendingInvitations error: $e');
      return [];
    }
  }

  /// Annule une invitation en attente (RLS : admin de la boutique uniquement).
  static Future<void> cancelInvitation(String invitationId) async {
    if (!await isOnline()) throw Exception('Connexion requise');
    await _db.from('pending_invitations').delete().eq('id', invitationId);
  }
  // ══ MAPPERS ═══════════════════════════════════════════════════════

  static ShopSummary _rowToShop(Map<String, dynamic> r) => ShopSummary(
    id: r['id'] as String, name: r['name'] as String,
    currency: r['currency'] as String? ?? 'XAF',
    country: r['country'] as String? ?? 'CM',
    sector: r['sector'] as String? ?? 'retail',
    isActive: r['is_active'] as bool? ?? true,
    ownerId: r['owner_id']?.toString(),
    phone: r['phone'] as String?, email: r['email'] as String?,
    createdAt: r['created_at'] != null
        ? DateTime.tryParse(r['created_at'] as String) : null,
    kind:         ShopKindX.fromKey(r['kind'] as String?),
    parentShopId: r['parent_shop_id'] as String?,
  );

  static UserRole _parseRole(String r) => switch (r) {
    'admin' => UserRole.admin, 'manager' => UserRole.manager, _ => UserRole.cashier,
  };

  static Map<String, dynamic> _productToMap(Product p) =>
      LocalStorageService.productToMap(p);

  static Map<String, dynamic> _productToSupabase(Product p) => {
    'id': p.id ?? '', 'store_id': p.storeId, 'category_id': p.categoryId,
    'brand': p.brand, 'name': p.name, 'description': p.description,
    'barcode': p.barcode, 'sku': p.sku,
    'price_buy': p.priceBuy, 'price_sell_pos': p.priceSellPos,
    'price_sell_web': p.priceSellWeb, 'tax_rate': p.taxRate,
    'stock_qty': p.stockQty, 'stock_min_alert': p.stockMinAlert,
    'status': p.status.key,
    'is_active': p.isActive, 'is_visible_web': p.isVisibleWeb,
    'image_url': p.imageUrl, 'rating': p.rating,
    'variants': p.variants.map(LocalStorageService.variantToMap).toList(),
    // expenses est List<Map> en local — Supabase stocke la somme en double
    'expenses': p.expenses.fold<double>(
        0, (sum, e) => sum + ((e['amount'] as num?)?.toDouble() ?? 0)),
  };

  static Product _supabaseToProduct(Map<String, dynamic> r) {
    final variants = ((r['variants'] as List?) ?? [])
        .map((v) => LocalStorageService.variantFromMap(Map<String, dynamic>.from(v as Map)))
        .toList();
    final createdRaw = r['created_at'];
    return Product(
      id: r['id'], storeId: r['store_id'], categoryId: r['category_id'],
      brand: r['brand'], name: r['name'], description: r['description'],
      barcode: r['barcode'], sku: r['sku'],
      priceBuy: (r['price_buy'] as num?)?.toDouble() ?? 0,
      priceSellPos: (r['price_sell_pos'] as num?)?.toDouble() ?? 0,
      priceSellWeb: (r['price_sell_web'] as num?)?.toDouble() ?? 0,
      taxRate: (r['tax_rate'] as num?)?.toDouble() ?? 0,
      stockQty: r['stock_qty'] as int? ?? 0,
      stockMinAlert: r['stock_min_alert'] as int? ?? 5,
      status: ProductStatusX.fromString(r['status'] as String?),
      isActive: r['is_active'] as bool? ?? true,
      isVisibleWeb: r['is_visible_web'] as bool? ?? false,
      imageUrl: r['image_url'], rating: r['rating'] as int? ?? 0,
      createdAt: createdRaw is String
          ? DateTime.tryParse(createdRaw)
          : (createdRaw is DateTime ? createdRaw : null),
      variants: variants,
      // Supabase stocke expenses comme un double (somme totale),
      // Hive stocke comme List<Map>. Gérer les deux formats.
      expenses: r['expenses'] is List
          ? (r['expenses'] as List)
              .map((e) => Map<String, dynamic>.from(e as Map)).toList()
          : r['expenses'] is num
              ? [{'description': 'Dépenses', 'amount': (r['expenses'] as num).toDouble()}]
              : [],
    );
  }

  // ══════════════════════════════════════════════════════════════════
  // CLIENTS
  // ══════════════════════════════════════════════════════════════════

  /// Sauvegarder un client : Hive immédiat + Supabase background.
  /// Valide l'unicité email/téléphone par boutique (sauf si skipValidation).
  static Future<void> saveClient(Client c, {bool skipValidation = false}) async {
    // 0. Validation unicité (email + phone par boutique)
    if (!skipValidation) {
      _validateClientLocalUniqueness(c);
      if (_i._isOnline) await _validateClientRemoteUniqueness(c);
    }
    // 1. Hive IMMÉDIATEMENT — offline-first
    HiveBoxes.clientsBox.put(c.id, _clientToMap(c));
    // 2. Supabase en arrière-plan — jamais bloquant
    _bgWrite({'table': 'clients', 'op': 'upsert', 'data': _clientToSupabase(c)});
    _notify('clients', c.storeId);
  }

  /// Vérifie en local (Hive) qu'aucun autre client de la même boutique
  /// n'utilise déjà le même email ou téléphone. Jette une Exception FR sinon.
  static void _validateClientLocalUniqueness(Client c) {
    final shopId = c.storeId;
    final email = c.email?.trim().toLowerCase();
    final phone = _normalizePhone(c.phone);
    if ((email == null || email.isEmpty) && (phone == null || phone.isEmpty)) {
      return;
    }
    for (final raw in HiveBoxes.clientsBox.values) {
      final m = Map<String, dynamic>.from(raw);
      if (m['store_id'] != shopId || m['id'] == c.id) continue;
      if (email != null && email.isNotEmpty) {
        final other = (m['email'] as String?)?.trim().toLowerCase();
        if (other != null && other.isNotEmpty && other == email) {
          throw Exception('Un client avec l\'email "$email" existe déjà');
        }
      }
      if (phone != null && phone.isNotEmpty) {
        final other = _normalizePhone(m['phone'] as String?);
        if (other != null && other.isNotEmpty && other == phone) {
          throw Exception('Un client avec le téléphone "${c.phone}" existe déjà');
        }
      }
    }
  }

  /// Vérifie en base Supabase qu'aucun autre client de la même boutique
  /// n'utilise déjà le même email ou téléphone.
  static Future<void> _validateClientRemoteUniqueness(Client c) async {
    final shopId = c.storeId;
    final email = c.email?.trim();
    final phone = c.phone?.trim();

    if (email != null && email.isNotEmpty) {
      final row = await _db.from('clients').select('id')
          .eq('store_id', shopId).ilike('email', email)
          .neq('id', c.id).maybeSingle();
      if (row != null) {
        throw Exception('Un client avec l\'email "$email" existe déjà');
      }
    }
    if (phone != null && phone.isNotEmpty) {
      final row = await _db.from('clients').select('id')
          .eq('store_id', shopId).eq('phone', phone)
          .neq('id', c.id).maybeSingle();
      if (row != null) {
        throw Exception('Un client avec le téléphone "$phone" existe déjà');
      }
    }
  }

  /// Normalise un numéro : retire espaces et tirets pour comparer
  /// "+237 6 11 22 33 44" et "+237611223344" comme identiques.
  static String? _normalizePhone(String? raw) {
    if (raw == null) return null;
    return raw.replaceAll(RegExp(r'[\s\-\.]'), '').trim();
  }

  /// Sync une commande vers Supabase en arrière-plan
  static void bgWriteOrder(Map<String, dynamic> orderMap) {
    _bgWrite({'table': 'orders', 'op': 'upsert', 'data': orderMap});
  }

  /// Supprimer une commande sur Supabase (immédiat si online, sinon queued)
  static void bgDeleteOrder(String orderId) {
    _bgWrite({'table': 'orders', 'op': 'delete',
      'col': 'id', 'val': orderId, 'data': {}});
  }

  /// Archive un client (soft-delete) : le masque des listes par défaut
  /// mais préserve son lien avec les commandes existantes.
  /// Inverse : pass `archived: false` pour désarchiver.
  static Future<void> archiveClient(String clientId,
      {bool archived = true}) async {
    final raw = HiveBoxes.clientsBox.get(clientId);
    if (raw == null) return;
    final client = _clientFromMap(Map<String, dynamic>.from(raw));
    final updated = client.copyWith(isArchived: archived);
    HiveBoxes.clientsBox.put(client.id, _clientToMap(updated));
    _bgWrite({'table': 'clients', 'op': 'upsert',
      'data': _clientToSupabase(updated)});
    _notify('clients', client.storeId);
  }

  /// Supprimer un client. Règle métier : refusé si le client est lié à
  /// au moins une commande (on préserve l'historique pour les rapports).
  static Future<void> deleteClient(String clientId, String storeId) async {
    final hasOrders = HiveBoxes.ordersBox.values.any((raw) {
      final m = Map<String, dynamic>.from(raw);
      return m['client_id'] == clientId;
    });
    if (hasOrders) {
      final raw = HiveBoxes.clientsBox.get(clientId);
      final name = raw is Map ? (raw['name'] as String? ?? '') : '';
      throw Exception(
          'Impossible de supprimer "${name.isEmpty ? 'ce client' : name}" : '
          'il a au moins une commande enregistrée. Supprime les commandes '
          'd\'abord ou archive ce client.');
    }
    HiveBoxes.clientsBox.delete(clientId);
    _bgWrite({'table': 'clients', 'op': 'delete',
      'col': 'id', 'val': clientId, 'data': {}});
    _notify('clients', storeId);
  }

  /// Lire les clients d'une boutique depuis Hive (lecture instantanée)
  /// Liste les clients d'une boutique.
  /// Par défaut les clients archivés sont masqués. Passer
  /// [includeArchived] = true pour récupérer la liste complète (utile
  /// pour la gestion / réactivation).
  static List<Client> getClientsForShop(String shopId,
      {bool includeArchived = false}) =>
      HiveBoxes.clientsBox.values
          .map((m) => _clientFromMap(Map<String, dynamic>.from(m)))
          .where((c) => c.storeId == shopId
                     && (includeArchived || !c.isArchived))
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));

  /// Recalcule totalSpent / totalOrders / lastVisitAt d'un client à partir
  /// des commandes complétées présentes dans Hive, puis sauvegarde.
  /// Appelé après chaque vente encaissée ou changement de statut → completed.
  static Future<void> refreshClientMetrics(String clientId, String shopId) async {
    final raw = HiveBoxes.clientsBox.get(clientId);
    if (raw == null) return;
    final client = _clientFromMap(Map<String, dynamic>.from(raw));

    double totalSpent = 0;
    int    totalOrders = 0;
    DateTime? lastVisit;

    for (final v in HiveBoxes.ordersBox.values) {
      final o = Map<String, dynamic>.from(v);
      if (o['shop_id']   != shopId)   continue;
      if (o['client_id'] != clientId) continue;
      if ((o['status'] as String?) != 'completed') continue;

      // Montant total = Σ lignes (custom_price ?? unit_price) × qty × (1 - disc/100)
      // + Σ frais - discount_amount + TVA sur (sous-total + frais - discount)
      final items = (o['items'] as List?) ?? [];
      double subtotal = 0;
      for (final raw in items) {
        final it = Map<String, dynamic>.from(raw);
        final qty   = ((it['quantity'] ?? it['qty']) as num?)?.toInt() ?? 0;
        final unit  = ((it['unit_price'] ?? it['price']) as num?)?.toDouble() ?? 0;
        final cust  = (it['custom_price'] as num?)?.toDouble();
        final disc  = (it['discount'] as num?)?.toDouble() ?? 0;
        subtotal += (cust ?? unit) * qty * (1 - disc / 100);
      }
      double fees = 0;
      final rawFees = o['fees'] as List?;
      if (rawFees != null) {
        for (final f in rawFees) {
          if (f is Map) fees += (f['amount'] as num?)?.toDouble() ?? 0;
        }
      }
      final discountAmt = (o['discount_amount'] as num?)?.toDouble() ?? 0;
      final taxRate     = (o['tax_rate'] as num?)?.toDouble() ?? 0;
      final taxable     = subtotal + fees - discountAmt;
      final orderTotal  = taxable + taxable * taxRate / 100;

      totalSpent  += orderTotal;
      totalOrders += 1;

      final dateStr = (o['completed_at'] ?? o['created_at']) as String?;
      final date = dateStr != null ? DateTime.tryParse(dateStr) : null;
      if (date != null && (lastVisit == null || date.isAfter(lastVisit))) {
        lastVisit = date;
      }
    }

    final updated = client.copyWith(
      totalSpent:  totalSpent,
      totalOrders: totalOrders,
      lastVisitAt: lastVisit ?? client.lastVisitAt,
    );
    // Le client existe déjà avec ce même email/téléphone — pas de validation
    await saveClient(updated, skipValidation: true);
  }

  /// Sync clients depuis Supabase → Hive

  static Future<void> syncClients(String shopId) async {
    try {
      final rows = await _db.from('clients').select()
          .eq('store_id', shopId)
          .timeout(const Duration(seconds: 10));
      final list = rows as List;
      final remoteIds = <String>{};
      for (final row in list) {
        final c = _clientFromSupabase(Map<String, dynamic>.from(row));
        remoteIds.add(c.id);
        await HiveBoxes.clientsBox.put(c.id, _clientToMap(c));
      }
      // Diff purge : supprimer les clients locaux de ce shop
      // qui n'existent plus distant.
      final staleKeys = <dynamic>[];
      for (final key in HiveBoxes.clientsBox.keys) {
        final raw = HiveBoxes.clientsBox.get(key);
        if (raw is! Map) continue;
        if (raw['store_id']?.toString() != shopId) continue;
        if (!remoteIds.contains(key.toString())) staleKeys.add(key);
      }
      for (final k in staleKeys) {
        await HiveBoxes.clientsBox.delete(k);
      }
      debugPrint('[DB] Clients sync: $shopId '
          '(${list.length} remote, ${staleKeys.length} purgés)');
    } catch (e) {
      debugPrint('[DB] syncClients erreur: $e');
    }
  }


  // ── Sérialisation Client ──────────────────────────────────────────

  // Hive persiste city/district séparément + address legacy pour compat.
  static Map<String, dynamic> _clientToMap(Client c) => {
    'id':           c.id,
    'store_id':     c.storeId,
    'name':         c.name,
    'phone':        c.phone,
    'email':        c.email,
    'city':         c.city,
    'district':     c.district,
    'address':      c.address,
    'notes':        c.notes,
    'created_at':   c.createdAt.toIso8601String(),
    'last_visit_at':c.lastVisitAt?.toIso8601String(),
    'total_orders': c.totalOrders,
    'total_spent':  c.totalSpent,
    'is_archived':  c.isArchived,
  };

  static Client _clientFromMap(Map<String, dynamic> m) => Client(
    id:           m['id'] as String,
    storeId:      m['store_id'] as String,
    name:         m['name'] as String,
    phone:        m['phone'] as String?,
    email:        m['email'] as String?,
    city:         m['city'] as String?,
    district:     m['district'] as String?,
    address:      m['address'] as String?,
    notes:        m['notes'] as String?,
    createdAt:    DateTime.parse(m['created_at'] as String),
    lastVisitAt:  m['last_visit_at'] != null
        ? DateTime.parse(m['last_visit_at'] as String) : null,
    totalOrders:  (m['total_orders'] as num?)?.toInt() ?? 0,
    totalSpent:   (m['total_spent']  as num?)?.toDouble() ?? 0,
    isArchived:   m['is_archived'] as bool? ?? false,
  );

  // Supabase : écrit address = "quartier, ville" pour rester compatible avec
  // la colonne existante. La colonne `tag` est toujours écrite à NULL — le
  // segment est désormais dérivé de totalOrders côté client.
  static Map<String, dynamic> _clientToSupabase(Client c) {
    final composite = _composeAddress(city: c.city, district: c.district,
        fallback: c.address);
    return {
      'id':           c.id,
      'store_id':     c.storeId,
      'name':         c.name,
      'phone':        c.phone,
      'email':        c.email,
      'address':      composite,
      'notes':        c.notes,
      'tag':          null,
      'created_at':   c.createdAt.toIso8601String(),
      'last_visit_at':c.lastVisitAt?.toIso8601String(),
      'total_orders': c.totalOrders,
      'total_spent':  c.totalSpent,
      'is_archived':  c.isArchived,
    };
  }

  // Lecture depuis Supabase : si city/district absents (colonnes legacy),
  // on tente de parser `address` au format "quartier, ville".
  static Client _clientFromSupabase(Map<String, dynamic> m) {
    final hasSplit = m['city'] != null || m['district'] != null;
    if (hasSplit) return _clientFromMap(m);
    final parsed = _parseLegacyAddress(m['address'] as String?);
    return _clientFromMap({
      ...m,
      'city':     parsed.city,
      'district': parsed.district,
    });
  }

  static String? _composeAddress({String? city, String? district,
      String? fallback}) {
    final c = city?.trim();
    final d = district?.trim();
    if ((c == null || c.isEmpty) && (d == null || d.isEmpty)) {
      return fallback?.trim().isEmpty == true ? null : fallback?.trim();
    }
    if (c != null && c.isNotEmpty && d != null && d.isNotEmpty) return '$d, $c';
    return (d != null && d.isNotEmpty) ? d : c;
  }

  static ({String? city, String? district}) _parseLegacyAddress(String? raw) {
    final s = raw?.trim() ?? '';
    if (s.isEmpty) return (city: null, district: null);
    final parts = s.split(',').map((p) => p.trim()).where((p) => p.isNotEmpty)
        .toList();
    if (parts.length >= 2) return (city: parts[1], district: parts[0]);
    return (city: null, district: null);
  }

  // Valeurs distinctes pour autocomplétion — lecture Hive instantanée.
  static List<String> getDistinctClientCities(String shopId) =>
      _distinct(getClientsForShop(shopId).map((c) => c.city));

  static List<String> getDistinctClientDistricts(String shopId) =>
      _distinct(getClientsForShop(shopId).map((c) => c.district));

  /// Libellés distincts des frais déjà saisis sur les commandes de la
  /// boutique (ex: "Frais de livraison", "Emballage"). Utilisé pour
  /// l'autocomplétion dans le dialog d'ajout de frais de commande.
  static List<String> getDistinctOrderFeeLabels(String shopId) {
    final labels = <String>[];
    try {
      if (!Hive.isBoxOpen(HiveBoxes.orders)) return const [];
      for (final raw in HiveBoxes.ordersBox.values) {
        final o = Map<String, dynamic>.from(raw);
        if (o['shop_id'] != shopId) continue;
        final fees = o['fees'] as List?;
        if (fees == null) continue;
        for (final f in fees) {
          if (f is Map) {
            final label = (f['label'] as String?)?.trim();
            if (label != null && label.isNotEmpty) labels.add(label);
          }
        }
      }
    } catch (_) {}
    return _distinct(labels);
  }

  static List<String> _distinct(Iterable<String?> values) {
    final seen = <String>{};
    final out  = <String>[];
    for (final v in values) {
      final s = v?.trim();
      if (s == null || s.isEmpty) continue;
      final k = s.toLowerCase();
      if (seen.add(k)) out.add(s);
    }
    out.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return out;
  }

}

/// Représente la variation de stock d'une variante détectée par
/// `_computeStockDiffs` lors d'un `saveProduct`. Utilisé pour générer
/// les `StockMovement` d'audit (type=adjustment ou entry).
class _StockDiff {
  final String variantId;
  final int    before;
  final int    after;
  final bool   isCreation;
  const _StockDiff({
    required this.variantId,
    required this.before,
    required this.after,
    required this.isCreation,
  });
  int get delta => after - before;
}