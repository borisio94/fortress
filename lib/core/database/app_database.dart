import 'package:hive_flutter/hive_flutter.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart' hide User;
import '../config/starter_units.dart';
import '../config/supabase_config.dart';
import '../services/notification_service.dart';
import '../storage/hive_boxes.dart';
import '../storage/local_storage_service.dart';
import '../storage/schema_migrator.dart';
import 'sync_error_verdict.dart';
import 'sync_protected_tables.dart';
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
import '../services/entity_cascade.dart';
import '../services/pending_image_upload_service.dart';
import '../permisions/user_plan.dart';

typedef OnDataChanged = void Function(String table, String shopId);

/// Levée par toute écriture utilisateur quand l'abonnement du compte
/// courant est expiré/inactif (gel total : consultation seule, seul le
/// renouvellement est possible). Son message s'affiche tel quel dans les
/// SnackBars/dialogs d'erreur existants (les call sites font déjà
/// `catch (e) => showError(e.toString())`).
class SubscriptionFrozenException implements Exception {
  const SubscriptionFrozenException();
  @override
  String toString() =>
      'Abonnement expiré — renouvelez votre forfait pour effectuer '
      'cette action.';
}

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
  Timer? _queueFlushTimer;
  bool _syncing  = false;
  bool _isOnline = false;

  /// Vrai si l'un des résultats connectivity_plus indique une interface
  /// réseau utilisable. IMPORTANT : sur **web**, connectivity_plus renvoie
  /// fréquemment `ConnectivityResult.other` (Safari sans Network
  /// Information API, etc.) au lieu de `wifi/ethernet` → l'ancien prédicat
  /// (wifi|mobile|ethernet) classait le web comme HORS-LIGNE en
  /// permanence, donc toutes les écritures partaient en file offline et
  /// n'étaient flushées que par hasard (délai 15–290 s). On considère
  /// `other` et `vpn` comme connectés : si c'est en réalité hors-ligne,
  /// `_executeOp` échouera et remettra l'op en file (filet de sécurité).
  static bool _hasNetInterface(List<ConnectivityResult> r) => r.any((x) =>
      x == ConnectivityResult.wifi ||
      x == ConnectivityResult.mobile ||
      x == ConnectivityResult.ethernet ||
      x == ConnectivityResult.vpn ||
      x == ConnectivityResult.other);
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

  /// Anti-écho realtime côté ORDERS — même rôle que `_recentLocalProductWrites`.
  ///
  /// Sans ça, une transition scheduled → processing ne tenait pas : le flow
  /// caisse fait 2-3 writes en cascade (updateOrderDelivery + recordPayment +
  /// updateOrderStatus). Chaque write déclenche un upsert Supabase + un
  /// snapshot realtime. Les events peuvent arriver dans le désordre, et
  /// l'event de pré-update (status='scheduled' encore) peut écraser le
  /// status='processing' fraîchement écrit en Hive → l'opérateur voyait la
  /// commande « revenir » à programmée. On marque l'id à chaque
  /// `bgWriteOrder` et on ignore l'event realtime tant que l'écho est
  /// dans la fenêtre (10 s).
  final Map<String, int> _recentLocalOrderWrites = {};

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

  /// Idem pour le livre de comptes partenaires (id entrée → timestamp ms).
  /// Cf. [_kLedgerEchoKey]. Empêche la purge passthrough d'effacer une
  /// entrée locale dont le push n'est pas encore confirmé côté Supabase.
  final Map<String, int> _recentLocalLedgerWrites = {};

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
  /// Échos d'écritures locales du livre partenaire (id → timestamp ms).
  /// Protège une entrée fraîchement créée/modifiée de la PURGE
  /// `_syncTablePassthrough` tant que son push Supabase n'est pas confirmé
  /// — y compris pendant un push ONLINE en vol (qui ne passe PAS par la
  /// file offline, d'où l'insuffisance du seul garde-fou pendingIds en
  /// web). TTL 24 h (financier → marge large). Persisté en settingsBox
  /// pour survivre à un reload navigateur.
  static const String _kLedgerEchoKey = '_recent_partner_ledger_writes';
  static const int _kLedgerEchoTtlMs = 24 * 60 * 60 * 1000;
  /// Tombstones d'entrées du livre partenaire supprimées localement.
  /// Le modèle est fusion-seule + re-push : sans tombstone, une entrée
  /// supprimée serait RE-POUSSÉE par tout appareil dont le Hive la
  /// contient encore (résurrection). Le tombstone bloque la ré-écriture
  /// Hive ET le re-push pour cet id. TTL 30 j (large — financier).
  static const String _kDeletedLedgerKey = '_deleted_partner_ledger_pending';
  static const int _kDeletedLedgerTtlMs = 30 * 24 * 60 * 60 * 1000;

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

  /// Verrou abonnement. `true` UNIQUEMENT si on SAIT positivement que
  /// l'abonnement du compte courant est expiré/inactif.
  ///
  /// Fail-open volontaire — retourne `false` (donc on laisse écrire) si :
  ///   - personne n'est connecté ;
  ///   - le plan n'est pas encore mis en cache (juste après login) ;
  ///   - super-admin ;
  ///   - le moindre doute / erreur.
  /// Ainsi on ne bloque JAMAIS par erreur un client en règle ; on ne gèle
  /// que lorsque le plan caché dit explicitement « inactif/expiré ».
  static bool get isSubscriptionFrozen {
    try {
      final uid = _db.auth.currentUser?.id;
      if (uid == null) return false;
      final prof = getCachedProfile(uid);
      if (prof != null && prof['is_super_admin'] == true) return false;
      final planMap = getCachedPlan(uid);
      if (planMap == null) return false;
      final plan = UserPlan.fromMap(planMap);
      if (plan.isSuperAdmin) return false;
      return !plan.isActive;
    } catch (_) {
      return false;
    }
  }

  /// Met à jour le cache plan local lu par [isSubscriptionFrozen]. À
  /// appeler après CHAQUE lecture fraîche de `get_user_plan` (login,
  /// renouvellement) pour que le verrou abonnement reflète l'état réel —
  /// sinon l'app resterait gelée même après un paiement valide.
  static Future<void> cachePlanMap(
      String userId, Map<String, dynamic> map) async {
    try {
      await HiveBoxes.settingsBox.put('user_plan_$userId', map);
    } catch (_) {}
  }

  /// À appeler en tête de chaque méthode d'écriture utilisateur. Lève
  /// [SubscriptionFrozenException] si l'abonnement est gelé → rien n'est
  /// écrit (ni Hive ni cloud) et l'UI affiche le message de renouvellement.
  static void _assertNotFrozen() {
    if (isSubscriptionFrozen) throw const SubscriptionFrozenException();
  }

  // ══ INIT ══════════════════════════════════════════════════════════

  static Future<void> init() async {
    // Au boot, on évite isOnline() qui ping Supabase : l'utilisateur n'est
    // pas encore authentifié, le ping échoue par RLS/timeout et `_isOnline`
    // resterait à false jusqu'au prochain changement d'interface.
    // L'état d'interface de connectivity_plus suffit pour l'init ;
    // les opérations qui ont besoin d'une vérif réelle appellent isOnline().
    final results = await Connectivity().checkConnectivity();
    _i._isOnline = _hasNetInterface(results);
    _i._listenConnectivity();
    // Sonde de JOIGNABILITÉ RÉELLE périodique. connectivity_plus est peu
    // fiable sur web (transitions offline→online souvent manquées → l'app ne
    // se re-synchronisait pas et l'utilisateur devait actualiser). Toutes les
    // 15 s : on teste réellement le backend, on corrige `_isOnline`, et sur une
    // VRAIE reconnexion on déclenche la re-synchro complète (`_onNetworkRestored`)
    // + le flush de la file. Filet fiable qui complète `_listenConnectivity`
    // (réaction rapide mais approximative).
    _i._queueFlushTimer?.cancel();
    _i._queueFlushTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => unawaited(_i._reachabilityTick()),
    );
    // Purge unique des entrées notifications au format historique
    // (id aléatoire pré-déterministe). Cf. NotificationService.notify
    // qui utilise désormais `kind|targetId|shopId` pour écraser au lieu
    // d'accumuler à chaque relance.
    NotificationService.purgeLegacyEntries();
    // Recharger les marqueurs anti-stale persistants (survivent au reload)
    // et purger ceux trop vieux pour rester pertinents.
    await _bootstrapAntiStaleMarkers();
    // Purge des brouillons périmés. Volontairement APRÈS les marqueurs
    // anti-écho, et dans sa propre méthode : `_bootstrapAntiStaleMarkers`
    // ne touche que `settingsBox`, pas la boîte produits.
    await _purgeExpiredDrafts();
    // NB : l'ancien correctif `_revertErroneousRemittances` (2026-06-21) a été
    // RETIRÉ — il soft-deletait toute écriture `remittance` dont la note valait
    // « Versement reçu du partenaire », c.-à-d. la note PAR DÉFAUT de chaque
    // marquage légitime « Marquer reçu ». Son drapeau de garde vivant dans le
    // settingsBox local (non synchronisé), il se re-déclenchait sur chaque
    // nouveau navigateur/appareil/redéploiement et effaçait les versements
    // reçus valides (puis propageait le soft-delete + tombstone à tous les
    // appareils) → le bandeau « versement en attente » réapparaissait seul.
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

  /// Supprime les brouillons dont l'échéance est passée (cf. `draftExpiresAt`).
  ///
  /// Suppression SÈCHE et purement locale : un brouillon n'a jamais été
  /// publié, il n'a ni vente ni mouvement de stock rattaché, et la RPC
  /// `delete_product` (soft-delete, motif obligatoire, archivage) serait
  /// hors de propos. La ligne distante part par la file d'écriture normale.
  static Future<void> _purgeExpiredDrafts() async {
    try {
      final now = DateTime.now();
      final expired = <String>[];
      for (final raw in HiveBoxes.productsBox.values) {
        final m = Map<String, dynamic>.from(raw);
        if (m['status'] != 'draft') continue;
        final rawExp = m['draft_expires_at'];
        final exp = rawExp is String ? DateTime.tryParse(rawExp) : null;
        if (exp != null && exp.isBefore(now) && m['id'] is String) {
          expired.add(m['id'] as String);
        }
      }
      if (expired.isEmpty) return;
      LocalStorageService.invalidateProductsCache();
      for (final id in expired) {
        await HiveBoxes.productsBox.delete(id);
        _bgWrite({'table': 'products', 'op': 'delete',
                  'col': 'id', 'val': id, 'data': {'id': id}});
      }
      debugPrint('[DB] Brouillons périmés purgés : ${expired.length}');
    } catch (e) {
      debugPrint('[DB] _purgeExpiredDrafts error: $e');
    }
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

      // Échos livre partenaire : recharger en mémoire (filtre TTL 24 h).
      final rawLed = box.get(_kLedgerEchoKey);
      if (rawLed is Map) {
        for (final e in rawLed.entries) {
          final ts = e.value is num ? (e.value as num).toInt() : 0;
          if (now - ts < _kLedgerEchoTtlMs) {
            _i._recentLocalLedgerWrites[e.key.toString()] = ts;
          }
        }
        await box.put(_kLedgerEchoKey,
            Map<String, int>.from(_i._recentLocalLedgerWrites));
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

      // Tombstones livre partenaire : purge des entrées expirées (30 j).
      final rawLedDel = box.get(_kDeletedLedgerKey);
      if (rawLedDel is Map) {
        final m = Map<String, dynamic>.from(rawLedDel);
        m.removeWhere((_, ts) => ts is! num
            || now - ts.toInt() > _kDeletedLedgerTtlMs);
        await box.put(_kDeletedLedgerKey, m);
        debugPrint('[DB] Tombstones livre partenaire actifs: ${m.length}');
      }
    } catch (e) {
      debugPrint('[DB] _bootstrapAntiStaleMarkers error: $e');
    }
  }

  /// Marque une entrée du livre partenaire comme supprimée localement.
  /// Empêche `syncPartnerLedger` (pull + re-push) et le realtime de la
  /// ressusciter avant/ après propagation du DELETE. TTL 30 j.
  static Future<void> markLedgerDeletionPending(String entryId) async {
    try {
      final box = HiveBoxes.settingsBox;
      final raw = box.get(_kDeletedLedgerKey);
      final m = raw is Map
          ? Map<String, dynamic>.from(raw)
          : <String, dynamic>{};
      m[entryId] = DateTime.now().millisecondsSinceEpoch;
      await box.put(_kDeletedLedgerKey, m);
    } catch (e) {
      debugPrint('[DB] markLedgerDeletionPending error: $e');
    }
  }

  /// L'entrée livre partenaire est-elle tombstone (suppression en attente
  /// de propagation, dans le TTL) ?
  static bool _isLedgerDeletionPending(String entryId) {
    try {
      final raw = HiveBoxes.settingsBox.get(_kDeletedLedgerKey);
      if (raw is! Map) return false;
      final ts = raw[entryId];
      if (ts is! num) return false;
      final age = DateTime.now().millisecondsSinceEpoch - ts.toInt();
      return age < _kDeletedLedgerTtlMs;
    } catch (_) {
      return false;
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

  /// Marque une entrée du livre partenaire comme écrite localement (création
  /// ou modification). Tant qu'elle est dans la fenêtre TTL [_kLedgerEchoTtlMs],
  /// `_syncTablePassthrough` ne la purgera PAS même si elle n'est pas encore
  /// présente côté Supabase (push online en vol, échec transitoire, reload
  /// web avant flush). Corrige le « solde partenaire qui revient » en web.
  static Future<void> markLocalLedgerWrite(String entryId) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    _i._recentLocalLedgerWrites[entryId] = nowMs;
    _i._recentLocalLedgerWrites.removeWhere(
        (_, ts) => nowMs - ts > _kLedgerEchoTtlMs);
    try {
      await HiveBoxes.settingsBox.put(
          _kLedgerEchoKey,
          Map<String, int>.from(_i._recentLocalLedgerWrites));
    } catch (_) {/* best effort */}
  }

  void _listenConnectivity() {
    _connectivitySub?.cancel();
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final wasOnline = _isOnline;
      _isOnline = _hasNetInterface(results);

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
        await syncDeliveryZones(shopId);
        await syncDeliveryQuartiers(shopId);
        await syncRestaurantTables(shopId);
        await syncIngredients(shopId);
        await syncRecipeIngredients(shopId);
        await syncRestaurantActivities(shopId);
        await syncStockItems(shopId);
        await syncFixedCharges(shopId);
        await syncLosses(shopId);
        await syncPayments(shopId);
        await syncBottleDeposits(shopId);
        await syncCashClosures(shopId);
        await syncStaff(shopId);
        await syncTimeRecords(shopId);
        await syncSalaryAdvances(shopId);
        await syncPayroll(shopId);
        await syncStaffPenalties(shopId);
        await syncStaffRatings(shopId);
        await syncStaffContests(shopId);
        await syncStaffAbsences(shopId);
        await syncStaffSettings(shopId);
        await syncDailyExpenses(shopId);
        await syncPartnerLedger(shopId);
        await syncStockLocations();
        await syncStockLevels(shopId);
        _notify('products',     shopId);
        _notify('clients',      shopId);
        _notify('stock_levels', shopId);
        // LES DROITS AUSSI ONT PU CHANGER PENDANT LA COUPURE, et rien ne les
        // relisait : `shop_memberships` n'est pas une table synchronisée, elle
        // est lue à la demande par `currentUserShopPermissionsProvider`. Cette
        // notification n'annonce pas une donnée reçue — elle dit « relis », ce
        // qui est exactement ce qu'on sait après un retour de réseau.
        _notify('shop_memberships', shopId);
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

  /// Sonde de joignabilité réelle (fiable sur web, contrairement à
  /// connectivity_plus). Corrige `_isOnline` et, sur une VRAIE transition
  /// hors-ligne→en-ligne, déclenche la re-synchro complète
  /// (`_onNetworkRestored`) — sans quoi l'utilisateur devait actualiser (F5)
  /// pour voir les changements distants après une coupure. Sinon (déjà en
  /// ligne) : simple flush de la file d'attente.
  Future<void> _reachabilityTick() async {
    final reachable = await _probeReachable();
    final wasOnline = _isOnline;
    _isOnline = reachable;
    if (reachable && !wasOnline) {
      debugPrint('[DB] ✅ Reconnexion (sonde) — re-synchro complète');
      await _onNetworkRestored();
    } else if (reachable) {
      unawaited(flushOfflineQueue());
    }
  }

  /// GET léger sur le health-check Supabase (CORS OK, ~100 octets). Toute
  /// réponse HTTP = serveur joignable ; erreur réseau/timeout/DNS = hors ligne.
  static Future<bool> _probeReachable() async {
    try {
      final res = await http
          .get(Uri.parse('${SupabaseConfig.url}/auth/v1/health'),
              headers: {'apikey': SupabaseConfig.anonKey})
          .timeout(const Duration(seconds: 5));
      return res.statusCode > 0;
    } catch (_) {
      return false;
    }
  }

  static void dispose() {
    _i._connectivitySub?.cancel();
    _i._queueFlushTimer?.cancel();
    _i._queueFlushTimer = null;
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
        // Postes de l'établissement (hotfix_160) : la liste modifiée sur un
        // appareil doit apparaître sur les autres sans redémarrage.
        .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public', table: 'job_titles',
        filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'shop_id', value: shopId),
        callback: (_) async {
          await syncMetadata(shopId);
          _notify('job_titles', shopId);
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
        // ── Frais de livraison par quartier (zones + quartiers) ────────
        .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public', table: 'delivery_zones',
        filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'shop_id', value: shopId),
        callback: (p) => _i._onTablePassthroughChange(
            p, HiveBoxes.deliveryZonesBox, 'delivery_zones', shopId))
        .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public', table: 'delivery_quartiers',
        filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'shop_id', value: shopId),
        callback: (p) => _i._onTablePassthroughChange(
            p, HiveBoxes.deliveryQuartiersBox, 'delivery_quartiers', shopId))
        // ── Plan de salle restaurant (tablette salle ↔ tel serveur) ────
        // Realtime INDISPENSABLE ici : deux appareils manipulent le même
        // plan de salle simultanément, un pull périodique ne suffirait pas.
        .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public', table: 'restaurant_tables',
        filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'shop_id', value: shopId),
        callback: (p) => _i._onTablePassthroughChange(
            p, HiveBoxes.restaurantTablesBox, 'restaurant_tables', shopId))
        // ── Finances restaurant (PR-A) : ingrédients + lignes de recette ──
        .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public', table: 'ingredients',
        filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'shop_id', value: shopId),
        callback: (p) => _i._onTablePassthroughChange(
            p, HiveBoxes.ingredientsBox, 'ingredients', shopId))
        .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public', table: 'recipe_ingredients',
        filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'shop_id', value: shopId),
        callback: (p) => _i._onTablePassthroughChange(
            p, HiveBoxes.recipeIngredientsBox, 'recipe_ingredients', shopId))
        // ── Finances restaurant (PR-B) : activités + articles stock ──────
        .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public', table: 'restaurant_activities',
        filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'shop_id', value: shopId),
        callback: (p) => _i._onTablePassthroughChange(
            p, HiveBoxes.restaurantActivitiesBox, 'restaurant_activities',
            shopId))
        .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public', table: 'stock_items',
        filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'shop_id', value: shopId),
        callback: (p) => _i._onTablePassthroughChange(
            p, HiveBoxes.stockItemsBox, 'stock_items', shopId))
        // ── Finances restaurant (PR-C) : charges fixes + pertes ──────────
        .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public', table: 'fixed_charges',
        filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'shop_id', value: shopId),
        callback: (p) => _i._onTablePassthroughChange(
            p, HiveBoxes.fixedChargesBox, 'fixed_charges', shopId))
        .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public', table: 'losses',
        filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'shop_id', value: shopId),
        callback: (p) => _i._onTablePassthroughChange(
            p, HiveBoxes.lossesBox, 'losses', shopId))
        // ── Règlements d'addition (Lot A) : la caisse et la tablette de
        //    salle doivent voir le même reste dû, sinon on encaisse deux fois.
        .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public', table: 'payments',
        filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'shop_id', value: shopId),
        callback: (p) => _i._onTablePassthroughChange(
            p, HiveBoxes.paymentsBox, 'payments', shopId))
        // ── Consignes d'emballages (Lot B) : le comptoir enregistre, la
        //    caisse voit le retour.
        .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public', table: 'bottle_deposits',
        filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'shop_id', value: shopId),
        callback: (p) => _i._onTablePassthroughChange(
            p, HiveBoxes.bottleDepositsBox, 'bottle_deposits', shopId))
        // ── Clôtures de caisse (Lot C) : le gérant voit l'écart depuis son
        //    téléphone, sans attendre de repasser à la boutique.
        .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public', table: 'cash_closures',
        filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'shop_id', value: shopId),
        callback: (p) => _i._onTablePassthroughChange(
            p, HiveBoxes.cashClosuresBox, 'cash_closures', shopId))
        // ── Personnel : fiches, pointage, avances, paie (Lot D). La badgeuse
        //    est un appareil, la paie s'ouvre sur un autre.
        .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public', table: 'employees',
        filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'shop_id', value: shopId),
        callback: (p) => _i._onTablePassthroughChange(
            p, HiveBoxes.employeesBox, 'employees', shopId))
        .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public', table: 'time_records',
        filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'shop_id', value: shopId),
        callback: (p) => _i._onTablePassthroughChange(
            p, HiveBoxes.timeRecordsBox, 'time_records', shopId))
        .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public', table: 'salary_advances',
        filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'shop_id', value: shopId),
        callback: (p) => _i._onTablePassthroughChange(
            p, HiveBoxes.salaryAdvancesBox, 'salary_advances', shopId))
        .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public', table: 'payroll',
        filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'shop_id', value: shopId),
        callback: (p) => _i._onTablePassthroughChange(
            p, HiveBoxes.payrollBox, 'payroll', shopId))
        // ── Tenue de l'équipe (hotfix_165). Realtime indispensable : l'excuse
        //    d'un départ anticipé se saisit sur la badgeuse, et c'est le
        //    téléphone du gérant qui doit la voir arriver pour la trancher.
        .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public', table: 'staff_penalties',
        filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'shop_id', value: shopId),
        callback: (p) => _i._onTablePassthroughChange(
            p, HiveBoxes.staffPenaltiesBox, 'staff_penalties', shopId))
        .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public', table: 'staff_ratings',
        filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'shop_id', value: shopId),
        callback: (p) => _i._onTablePassthroughChange(
            p, HiveBoxes.staffRatingsBox, 'staff_ratings', shopId))
        .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public', table: 'staff_contests',
        filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'shop_id', value: shopId),
        callback: (p) => _i._onTablePassthroughChange(
            p, HiveBoxes.staffContestsBox, 'staff_contests', shopId))
        // Une mise à pied prononcée depuis le téléphone du gérant doit
        // atteindre la badgeuse AVANT que l'intéressé n'y tape son code.
        .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public', table: 'staff_absences',
        filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'shop_id', value: shopId),
        callback: (p) => _i._onTablePassthroughChange(
            p, HiveBoxes.staffAbsencesBox, 'staff_absences', shopId))
        // ── Dépenses quotidiennes (Lot E) : saisies au marché, lues à la
        //    caisse (elles sortent du tiroir) et au bilan.
        .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public', table: 'daily_expenses',
        filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'shop_id', value: shopId),
        callback: (p) => _i._onTablePassthroughChange(
            p, HiveBoxes.dailyExpensesBox, 'daily_expenses', shopId))
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

  /// Coupe TOUS les abonnements Realtime de boutique. À appeler au LOGOUT.
  ///
  /// Sans ça, après la purge Hive du logout le websocket de l'ancienne
  /// boutique restait ouvert (AdaptiveScaffold ne se désabonne pas au dispose)
  /// et pouvait RE-REMPLIR les box vidées → fuite des données du compte
  /// précédent vers le suivant sur un appareil partagé.
  ///
  /// Contrairement à [dispose] (réservé à l'arrêt complet de l'app), on
  /// PRÉSERVE le monitoring de connectivité et le timer de flush de la file :
  /// ils sont initialisés UNE FOIS au boot dans [init] et ne sont PAS recréés
  /// au login — les tuer ici casserait la synchro offline du prochain compte.
  /// Les canaux, eux, sont recréés au prochain login via
  /// `AdaptiveScaffold.initState → subscribeToShop`.
  static void unsubscribeAllShops() {
    for (final ch in List.of(_i._channels.values)) {
      try { ch.unsubscribe(); } catch (_) {}
    }
    _i._channels.clear();
  }

  /// Pull complet déclenchable depuis l'UI (pull-to-refresh) — variante
  /// publique de `_initialPullForShop`. À utiliser depuis un
  /// `RefreshIndicator.onRefresh`. Awaitable, pour que le spinner
  /// natif disparaisse à la fin.
  static Future<void> pullAllForShop(String shopId) =>
      _initialPullForShop(shopId);

  /// Actualisation MANUELLE d'une boutique (geste « tirer vers le bas »,
  /// bouton Actualiser) : vide la file hors ligne PUIS tire toutes les tables.
  ///
  /// L'ordre n'est pas négociable (cf. `onAppResumed`) : `syncOrders` purge
  /// les commandes locales absentes du serveur, et une commande créée hors
  /// ligne pas encore poussée en fait partie. Tirer d'abord la ferait
  /// disparaître.
  ///
  /// Retourne `false` si le backend est injoignable : rien n'est tiré, les
  /// données locales restent affichées telles quelles.
  static Future<bool> refreshShopData(String shopId) async {
    if (!await isOnline()) return false;
    await flushOfflineQueue();
    await pullAllForShop(shopId);
    return true;
  }

  /// Re-sync rapide déclenché au RETOUR de l'app au premier plan (cf.
  /// observateur de cycle de vie dans `app.dart`).
  ///
  /// Sur web, le navigateur SUSPEND le websocket Realtime quand l'onglet
  /// (ou l'écran du téléphone) passe en arrière-plan. Les changements
  /// distants survenus pendant ce temps — typiquement une commande
  /// validée par le client via le lien de suivi — n'arrivent qu'à la
  /// reconnexion spontanée du socket, parfois après un long délai. D'où
  /// le ressenti « le statut change et la notif arrive, mais très tard ».
  ///
  /// Ce hook force un pull immédiat des commandes de chaque boutique
  /// abonnée dès le retour → statut à jour et cloche quasi-instantanés.
  /// `syncOrders` détecte les transitions par diff du statut Hive et émet
  /// les notifications manquées (dédup → pas de double avec le realtime).
  static Future<void> onAppResumed() async {
    // VIDER LA FILE AVANT DE TIRER — ordre non négociable.
    //
    // `syncOrders` purge les commandes locales absentes du serveur. Une
    // commande créée hors ligne et pas encore poussée est absente du serveur
    // sans être périmée : tirer avant d'avoir poussé la ferait disparaître
    // définitivement. `_onNetworkRestored` respecte déjà cet ordre (flush
    // puis sync) ; ce hook, lui, tirait directement.
    //
    // LIMITE ASSUMÉE : `flushOfflineQueue` sort immédiatement si un flush est
    // déjà en cours (`_syncing`). Dans ce cas on tire quand même. La fenêtre
    // est fortement réduite, pas refermée — la garde anti-purge de
    // `syncOrders` est la seconde ligne de défense.
    await flushOfflineQueue();
    for (final shopId in List.of(_i._channels.keys)) {
      try {
        await syncOrders(shopId);
      } catch (e) {
        debugPrint('[DB] onAppResumed syncOrders($shopId) err: $e');
      }
    }
  }

  /// Pull initial de toutes les tables métier pour une boutique.
  /// Appelé au `subscribeToShop` — idempotent, safe à rappeler.
  /// Fire-and-forget : n'attend pas, ne bloque pas l'UI.
  static Future<void> _initialPullForShop(String shopId) async {
    // ── PHASE 1 (séquentielle, OBLIGATOIRE en tête) ──────────────────────
    // stock_locations puis stock_levels DOIVENT précéder syncProducts
    // (→ migrateShopStocksToLocationsV1) et scanStockNotifications. Seule
    // vraie dépendance d'ordre du pull initial.
    try {
      await syncStockLocations();
    } catch (e) { debugPrint('[DB] initial syncStockLocations: $e'); }
    try {
      await syncStockLevels(shopId);
      _notify('stock_levels', shopId);
    } catch (e) { debugPrint('[DB] initial syncStockLevels: $e'); }

    // ── PHASE 2 (PARALLÈLE) ──────────────────────────────────────────────
    // Toutes ces synchros écrivent dans des box Hive distinctes et
    // indépendantes → on les lance en parallèle. Le temps total passe de
    // « somme des pulls » (~5-6 s) à « durée du pull le plus lent »
    // (~1-2 s). Chaque tâche est isolée en try/catch (un échec n'affecte
    // pas les autres) et notifie l'UI dès que SA table est arrivée
    // (rafraîchissement progressif).
    Future<void> task(String name, Future<void> Function() body) async {
      try {
        await body();
      } catch (e) {
        debugPrint('[DB] initial $name: $e');
      }
    }

    await Future.wait<void>([
      task('syncClients', () async {
        await syncClients(shopId);
        _notify('clients', shopId);
      }),
      task('syncPartnerLedger', () => syncPartnerLedger(shopId)),
      task('syncProducts', () async {
        await syncProducts(shopId);
        _notify('products', shopId);
        // Rejoue les alertes stock pour les produits déjà bas/épuisés
        // (le Realtime ne notifie que les changements futurs).
        scanStockNotifications(shopId);
        // Réconciliation UNIQUE : réaligne les StockLevel boutique sur les
        // variantes (corrige les ventes PASSÉES où la garde anti-écho avait
        // bloqué la synchro → stock « figé » dans l'inventaire/grille).
        await _reconcileShopStockLevelsOnce(shopId);
      }),
      task('syncOrders', () async {
        await syncOrders(shopId);
        _notify('orders', shopId);
      }),
      task('syncExpenses', () async {
        await syncExpenses(shopId);
        _notify('expenses', shopId);
      }),
      task('syncMetadata', () => syncMetadata(shopId)),
      task('syncSuppliers', () => syncSuppliers(shopId)),
      task('syncIncidents', () => syncIncidents(shopId)),
      task('syncStockMovements', () => syncStockMovements(shopId)),
      task('syncReceptions', () => syncReceptions(shopId)),
      task('syncPurchaseOrders', () => syncPurchaseOrders(shopId)),
      task('syncStockArrivals', () => syncStockArrivals(shopId)),
      task('syncDeliveryTransfers', () => syncDeliveryTransfers(shopId)),
      task('syncDeliveryZones', () => syncDeliveryZones(shopId)),
      task('syncDeliveryQuartiers', () => syncDeliveryQuartiers(shopId)),
      task('syncRestaurantTables', () => syncRestaurantTables(shopId)),
      task('syncIngredients', () => syncIngredients(shopId)),
      task('syncRecipeIngredients', () => syncRecipeIngredients(shopId)),
      task('syncRestaurantActivities', () => syncRestaurantActivities(shopId)),
      task('syncStockItems', () => syncStockItems(shopId)),
      task('syncFixedCharges', () => syncFixedCharges(shopId)),
      task('syncLosses', () => syncLosses(shopId)),
      task('syncPayments', () => syncPayments(shopId)),
      task('syncBottleDeposits', () => syncBottleDeposits(shopId)),
      task('syncCashClosures', () => syncCashClosures(shopId)),
      task('syncStaff', () => syncStaff(shopId)),
      task('syncTimeRecords', () => syncTimeRecords(shopId)),
      task('syncSalaryAdvances', () => syncSalaryAdvances(shopId)),
      task('syncPayroll', () => syncPayroll(shopId)),
      task('syncStaffPenalties', () => syncStaffPenalties(shopId)),
      task('syncStaffRatings', () => syncStaffRatings(shopId)),
      task('syncStaffContests', () => syncStaffContests(shopId)),
      task('syncStaffAbsences', () => syncStaffAbsences(shopId)),
      task('syncStaffSettings', () => syncStaffSettings(shopId)),
      task('syncDailyExpenses', () => syncDailyExpenses(shopId)),
      task('syncActivityLogs', () async {
        await syncActivityLogs(shopId);
        _notify('activity_logs', shopId);
      }),
    ]);
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
      if (!_hasNetInterface(r)) return false;

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

  /// Identifiants dont une écriture est ENCORE EN FILE pour [table].
  ///
  /// Garde anti-purge : une ligne locale absente du serveur mais dont le push
  /// n'est pas confirmé n'est PAS un résidu à supprimer — c'est une écriture
  /// en vol. La purger perd définitivement une commande ou une dépense créée
  /// hors ligne.
  ///
  /// Diffère VOLONTAIREMENT de la garde interne à `_syncTablePassthrough` sur
  /// deux points, et c'est tout l'intérêt :
  ///   • `update` est accepté — `bgUpdateOrder` enfile ce type pour les
  ///     mutations partielles (paiement, livraison, frais), c'est-à-dire
  ///     précisément celles qui portent l'argent ;
  ///   • l'identifiant est lu dans `data['id']` OU `match['id']`, ce dernier
  ///     étant l'emplacement qu'utilisent les ops `update`.
  /// Ne filtrer que `insert`/`upsert` sur `data['id']` laisserait ces
  /// écritures sans protection tout en donnant l'illusion du contraire.
  ///
  /// `delete` est exclu à dessein : une suppression en file signifie que la
  /// ligne DOIT partir — l'épargner irait contre l'intention.
  static Set<String> _pendingIdsFor(String table) {
    final ids = <String>{};
    try {
      for (final raw in HiveBoxes.offlineQueueBox.values) {
        // PAS de `if (raw is! Map)` ici : la boîte est déclarée `Box<Map>`
        // (hive_boxes.dart), donc `.values` produit des `Map` NON nullables
        // et le test serait du code mort — l'analyseur le signale.
        //
        // Les purges voisines gardent le leur à juste titre : elles passent
        // par `box.get(key)`, qui retourne `Map?`. La symétrie n'est
        // qu'apparente, ne pas « rétablir » celui-ci.
        if (raw['table']?.toString() != table) continue;
        final opType = raw['op']?.toString();
        if (opType != 'insert' && opType != 'upsert' && opType != 'update') {
          continue;
        }
        final d = raw['data'];
        final m = raw['match'];
        final id = (d is Map ? d['id'] : null) ?? (m is Map ? m['id'] : null);
        if (id != null) ids.add(id.toString());
      }
    } catch (_) {/* best effort — en cas de doute on ne purge pas */}
    return ids;
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
        //
        // La liste vivait ici, en dur, et deux autres copies vivaient plus bas.
        // Elles avaient divergé. Elle est désormais dans
        // `sync_protected_tables.dart`, unique et testée.
        final isCritical = survivesRetryCap(table);

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

        // Pour les critiques : log persistant dès la 3e tentative puis à
        // chaque palier de 10, AVEC l'erreur serveur réelle (et non un
        // message générique « vente bloquée » trompeur). Le libellé
        // nomme la vraie table (orders=commande, sales=vente,
        // expenses=dépense) pour ne plus dire « vente » à tort.
        if (isCritical && (retries == 3 || (retries > 0 && retries % 10 == 0))) {
          final realErr = op['_last_error']?.toString();
          final libelle = switch (table) {
            'expenses' => 'dépense',
            'orders'   => 'commande',
            'sales'    => 'vente',
            _          => table,
          };
          _logSyncError(op,
              'CRITIQUE — $libelle ($table) bloquée après $retries '
              'tentatives. Cause serveur : '
              '${realErr ?? "inconnue (voir console)"}');
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

      // ── Strip schema_version avant push Supabase ───────────────────
      // Ce champ est ajouté par les toMap() pour le pattern de migration
      // (cf. lib/core/storage/schema_migrator.dart). Il est utile EN
      // LOCAL (Hive) pour décider d'appliquer les migrations à la lecture,
      // mais les tables Supabase n'ont pas cette colonne → un push avec
      // `schema_version` provoque une erreur PostgREST "column not found"
      // et la file de retry abandonne après 10 tentatives. On le retire
      // ici pour rester compatible sans devoir ajouter la colonne à
      // chaque table SQL.
      data.remove('schema_version');

      // ── Garde-fou ops orphelines ────────────────────────────────────
      // Si l'op référence un shop_id qui n'existe plus dans le Hive
      // local (boutique supprimée côté super-admin, ou orpheline d'un
      // ancien compte recréé), inutile de la pousser : Supabase
      // rejettera systématiquement avec un 42501 (RLS) ou 23503 (FK).
      // On la drop silencieusement pour éviter la boucle de retry qui
      // sature la file et bloque la bannière sync sur "1 erreur"
      // permanente. Couvre shop_id (la plupart des tables) et store_id
      // (clients, products).
      final orphanShopId = (data['shop_id'] ?? data['store_id'])?.toString();
      if (orphanShopId != null && orphanShopId.isNotEmpty
          && LocalStorageService.getShop(orphanShopId) == null) {
        debugPrint('[DB] ⏭️  Op droppée — shop inexistant localement '
            '(table=$table op=$type shop=$orphanShopId)');
        return true;
      }

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
        // DELETE — un filtre d'égalité par défaut (`col`/`val`), ou plusieurs
        // via `match`. Le second est indispensable dès que la colonne filtrée
        // n'est pas unique à l'échelle de la base : supprimer le poste
        // « Serveur » par son seul nom l'effacerait dans TOUTES les boutiques
        // de l'utilisateur, pas seulement la sienne.
        case 'delete':
          final dmatch = (op['match'] as Map?)?.cast<String, dynamic>();
          if (dmatch != null && dmatch.isNotEmpty) {
            var dq = _db.from(table).delete();
            for (final e in dmatch.entries) {
              dq = dq.eq(e.key, e.value);
            }
            await dq;
          } else {
            await _db.from(table).delete().eq(op['col'] as String, op['val']);
          }
        case 'insert': await _db.from(table).insert(data);
        // UPDATE ciblé par filtres d'égalité (op['match']). Un seul ordre
        // serveur met à jour toutes les lignes correspondantes — utilisé
        // pour propager en cascade les coordonnées d'un client sur le
        // snapshot figé (client_name/client_phone) de TOUTES ses commandes.
        case 'update':
          final match = (op['match'] as Map?)?.cast<String, dynamic>()
              ?? const <String, dynamic>{};
          var q = _db.from(table).update(data);
          for (final e in match.entries) {
            q = q.eq(e.key, e.value);
          }
          await q;
        // RPC offline-queued (hotfix_084 : delete_sale / restore_sale).
        // Le `name` est porté par `op['name']`, les params par `op['data']`.
        // La signature unique `{name, data}` permet à n'importe quelle RPC
        // future d'être enqueable sans changer ce switch. Les erreurs
        // P0001 (logique métier) sont considérées comme permanentes et
        // droppées de la queue après log — réessayer ne marchera pas.
        case 'rpc':
          final name = op['name'] as String? ?? '';
          if (name.isEmpty) {
            throw Exception('rpc_name_missing');
          }
          await _db.rpc(name, params: data);
      }
      return true;
    } catch (e) {
      final err = e.toString();
      // Mémorise l'erreur Postgres RÉELLE sur l'op (persistée avec elle
      // dans la queue) → la bannière "Synchro incomplète" peut afficher
      // la vraie cause au lieu d'un message générique.
      op['_last_error'] = err;
      debugPrint('[DB] ✗ Op failed table=${op['table']} op=${op['op']} err=$err');

      // Lu AVANT le verdict : depuis que la clé étrangère manquante est
      // temporaire sur une table protégée, le verdict dépend de la table.
      final failedTable = op['table'] as String? ?? '';

      // ── Erreurs PERMANENTES → supprimer de la queue (réessayer ne sert à rien)
      if (isDefinitiveSyncError(err, failedTable)) {
        // Duplicate key (23505) = idempotence normale (rejeu offline d'une op
        // déjà appliquée par realtime, double-tap UI, etc.). On avale
        // silencieusement, sinon la bannière "Synchro incomplète" reste
        // affichée à vie alors que tout est cohérent côté serveur.
        if (err.contains('23505')) {
          debugPrint('[DB] 23505 ignoré (idempotence) → supprimé de la queue');
          return true;
        }

        // CAS PARTICULIER : `transition_interdite` sur orders.
        // Ce n'est PAS une vraie erreur — c'est un conflit multi-device :
        // un autre appareil a déjà fait avancer la commande dans le
        // workflow (ex: completed) pendant qu'on essayait de la pousser
        // dans un état antérieur (ex: processing). Le trigger serveur a
        // raison : l'état local Hive est obsolète. Le bon réflexe est de
        // pull depuis Supabase pour aligner Hive (best-effort, async) et
        // de DROPPER l'op locale (la rejouer ne marchera jamais). Pas de
        // bannière critique pour ce cas — c'est une réconciliation
        // normale, pas une perte d'écriture.
        if (failedTable == 'orders'
            && err.contains('P0001')
            && err.contains('transition_interdite')) {
          final shopId = (op['data'] as Map?)?['shop_id'] as String?;
          if (shopId != null && shopId.isNotEmpty) {
            // Fire-and-forget : on n'attend pas le sync pour rendre la
            // décision « drop ». Erreur de sync silencieuse — Hive sera
            // aligné à la prochaine tentative si celle-ci échoue.
            Future.microtask(() async {
              try {
                await syncOrders(shopId);
              } catch (e) {
                debugPrint('[DB] resync après transition_interdite: $e');
              }
            });
          }
          debugPrint('[DB] transition_interdite (conflit multi-device) '
              '→ drop op + resync orders($shopId)');
          return true;
        }

        // Tables financières critiques : on n'ABANDONNE JAMAIS en silence
        // une écriture (sinon perte d'argent invisible). On garde l'op en
        // file (réessai + bannière "Synchro incomplète" visible) et on
        // journalise. Le garde-fou anti-purge protège la ligne locale tant
        // que l'op est en file → le solde ne peut plus revenir en arrière.
        if (survivesPermanentError(failedTable)) {
          debugPrint('[DB] Erreur permanente sur table critique '
              '"$failedTable" → GARDÉE en file (pas d\'abandon silencieux)');
          _logSyncError(op, err);
          return false;
        }

        debugPrint('[DB] Erreur permanente → supprimé de la queue');
        _logSyncError(op, err); // journaliser pour débogage
        return true;
      }

      // ── Table inexistante (42P01) → afficher le SQL de création
      //
      // `does not exist` a été RETIRÉ de ce test : une colonne absente produit
      // elle aussi ce libellé (`column "x" ... does not exist`), et retombait
      // donc ici — où on lui proposait de créer la TABLE, ce qui n'a aucun
      // sens quand la table existe et qu'il ne manque qu'une colonne. Ce cas
      // est désormais traité plus haut comme une dérive de schéma permanente.
      //
      // Aucune donnée ne peut être perdue par ce retrait : une erreur de table
      // manquante sans le code `42P01` retombe en fin de fonction sur
      // `return false` — l'op reste en file, exactement comme avant. Seul
      // l'affichage du SQL de création lui échappe.
      if (err.contains('42P01')) {
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

  /// LES OPÉRATIONS EN FILE, une par une, pour l'écran de synchronisation.
  ///
  /// [pendingOpsCount] et [syncQueueStats] ne rendent que des nombres, et
  /// `getSyncErrors` ne rend que ce qui a été JOURNALISÉ — une op qui échoue
  /// sans journal n'apparaissait donc nulle part. On pouvait tout vider, jamais
  /// regarder.
  ///
  /// La clé Hive est rendue avec chaque op : c'est elle qui permet d'en
  /// abandonner une seule (cf. [discardOp]).
  ///
  /// Triées par nombre de tentatives DÉCROISSANT : celles qui bloquent depuis
  /// le plus longtemps sont celles qu'on cherche.
  static List<({dynamic key, String table, String op, int retries,
      String? lastError, String? lastRetry})> get pendingOps {
    final out = <({dynamic key, String table, String op, int retries,
        String? lastError, String? lastRetry})>[];
    try {
      final box = HiveBoxes.offlineQueueBox;
      for (final key in box.keys) {
        final raw = box.get(key);
        if (raw == null) continue;
        try {
          final m = Map<String, dynamic>.from(raw);
          out.add((
            key: key,
            table: m['table']?.toString() ?? '?',
            op: m['op']?.toString() ?? '?',
            retries: (m['_retries'] as int?) ?? 0,
            lastError: m['_last_error']?.toString(),
            lastRetry: m['_last_retry']?.toString(),
          ));
        } catch (_) {/* ligne corrompue : ignorée */}
      }
    } catch (e) {
      debugPrint('[DB] pendingOps err: $e');
    }
    out.sort((a, b) => b.retries.compareTo(a.retries));
    return out;
  }

  /// Abandonne UNE opération, par sa clé.
  ///
  /// C'est une perte d'écriture DÉFINITIVE, et c'est tout l'intérêt : sans
  /// elle, la seule issue devant une op définitivement invalide était « Vider
  /// la queue », qui les perd toutes. Protéger une table de l'abandon
  /// automatique sans offrir l'abandon choisi revenait à concentrer la perte au
  /// lieu de l'étaler — et à la rendre volontaire.
  ///
  /// Journalisé avant suppression : une fois l'op partie, plus rien ne dit ce
  /// qui a été abandonné ni par qui.
  static Future<void> discardOp(dynamic key) async {
    try {
      final box = HiveBoxes.offlineQueueBox;
      final raw = box.get(key);
      if (raw == null) return;
      try {
        _logSyncError(Map<String, dynamic>.from(raw),
            'Abandonnée manuellement depuis l\'écran de synchronisation');
      } catch (_) {/* le journal ne doit pas empêcher l'abandon */}
      await box.delete(key);
      debugPrint('[DB] 🗑️ Op abandonnée manuellement: $key');
    } catch (e) {
      debugPrint('[DB] discardOp err: $e');
    }
  }

  /// Nombre d'écritures protégées bloquées depuis ≥ 10 tentatives.
  ///
  /// C'est ce compteur qui allume la bannière « Synchro incomplète ». Il était
  /// la TROISIÈME liste, la plus courte des trois : `restaurant_tables` était
  /// protégée des deux abandons mais ne comptait pas ici, donc survivait sans
  /// que personne ne l'apprenne. Une op gardée dont on ne dit rien est une op
  /// perdue avec un délai.
  static int get stuckCriticalOpsCount {
    var n = 0;
    for (final raw in HiveBoxes.offlineQueueBox.values) {
      try {
        final m = Map<String, dynamic>.from(raw);
        final table = m['table'] as String? ?? '';
        final retries = (m['_retries'] as int?) ?? 0;
        if (countsAsStuck(table) && retries >= 10) n++;
      } catch (_) {}
    }
    return n;
  }

  // Écrire en arrière-plan si online, sinon enqueue
  static void _bgWrite(Map<String, dynamic> op) {
    // Catch-all : couvre les écritures qui ne passent pas par une méthode
    // utilisateur nommée (commandes/ventes, livre partenaire, liens
    // courts, etc.). Gelé → on n'exécute ni ne met en file (aucune
    // persistance cloud). Fail-open si le plan n'est pas connu.
    if (isSubscriptionFrozen) {
      debugPrint('[DB] ✗ écriture refusée (abonnement gelé) '
          'table=${op['table']} op=${op['op']}');
      return;
    }
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

  /// Upsert (insert-or-update sur la PK) via la file offline. Idempotent :
  /// un rejeu (echo realtime, double-tap, flush queue) ne provoque pas de
  /// 23505. À privilégier sur [bgInsert] pour les écritures Hive-first
  /// rejouables (ex: livre de comptes partenaires).
  static void bgUpsert(String table, Map<String, dynamic> data) {
    _bgWrite({'table': table, 'op': 'upsert', 'data': data});
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
  synced_to_cloud  boolean          not null default false,
  table_id         text,
  covers           integer,
  order_type       text             not null default 'takeaway',
  sent_to_kitchen  boolean          not null default false,
  kitchen_ready    boolean          not null default false,
  served           boolean          not null default false,
  finished         boolean          not null default false
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
  track_stock boolean not null default true,
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

  /// Les unités proposées à une boutique neuve — voir `starter_units.dart`.
  ///
  /// Une boutique neuve n'en recevait aucune : le premier produit saisi butait
  /// sur un champ « unité » sans le moindre choix, et il fallait deviner qu'on
  /// pouvait en créer, dans un écran de paramètres qu'on ne cherche pas quand
  /// on remplit une fiche produit.
  ///
  /// PAS PAR `saveUnit`, et c'est délibéré : elle journalise un
  /// `unit_created` par appel. Six lignes « untel a créé une unité » au
  /// journal d'activité d'une boutique de trente secondes attribueraient au
  /// propriétaire une saisie qu'il n'a jamais faite. On écrit la liste d'un
  /// coup et on pousse chaque ligne.
  ///
  /// Idempotent par construction : `onConflict` côté Supabase, et la clé Hive
  /// est écrite en une fois.
  static Future<void> _seedStarterUnits({
    required String shopId,
    required String sector,
  }) async {
    final units = starterUnitsFor(sector);
    if (units.isEmpty) return;
    try {
      await HiveBoxes.settingsBox.put('units_$shopId', units);
    } catch (e) {
      debugPrint('[DB] unités d\'amorçage Hive err: $e');
    }
    for (final name in units) {
      _bgWrite({
        'table': 'units', 'op': 'upsert',
        'data': {'shop_id': shopId, 'name': name},
        'onConflict': 'shop_id,name',
      });
    }
    _notify('units', shopId);
  }

  static Future<ShopSummary> createShop({
    required String name, required String sector,
    required String currency, required String country,
    String? phone, String? email,
  }) async {
    _assertNotFrozen();
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

    // La membership « owner » est créée côté serveur par le trigger
    // trg_create_owner_membership (hotfix_115, SECURITY DEFINER). On n'insère
    // plus depuis le client : l'INSERT applicatif dépendait du contexte
    // RLS/session juste après le sign-up et échouait par moments (42501).

    final shop = _rowToShop(row);
    await LocalStorageService.saveShop(shop);
    await LocalStorageService.saveMembership(
        userId: userId, shopId: shop.id,
        shopName: shop.name, role: UserRole.admin);

    await _seedStarterUnits(shopId: shop.id, sector: sector);

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
    // Pas de `sector` : le type d'établissement est FIGÉ à la création
    // (cf. kCreationSectors). Le basculer sur une boutique en exploitation
    // laisserait des données orphelines — commandes rattachées à des tables
    // sur une boutique devenue e-commerce, plan de salle inaccessible.
    // `createShop` reste le seul chemin d'écriture du secteur.
    String? name,
    String? currency, String? country,
    String? phone, String? whatsappPhone, String? email,
    String? facebookPixelId,
    int? partnerDebtAlertDays,
  }) async {
    _assertNotFrozen();
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
    if (currency != null) payload['currency'] = currency;
    if (country  != null) payload['country']  = country;
    if (phone    != null) payload['phone']    = phone.trim().isEmpty ? null : phone.trim();
    if (whatsappPhone != null) {
      payload['whatsapp_phone'] =
          whatsappPhone.trim().isEmpty ? null : whatsappPhone.trim();
    }
    if (email    != null) payload['email']    = email.trim().isEmpty ? null : email.trim();
    // facebook_pixel_id : chaîne vide → null (déconnexion du pixel).
    if (facebookPixelId != null) {
      payload['facebook_pixel_id'] =
          facebookPixelId.trim().isEmpty ? null : facebookPixelId.trim();
    }
    // Seuil d'alerte d'ancienneté des dettes partenaires. Borné ici AUSSI,
    // et pas seulement par le CHECK SQL (hotfix_178) : une valeur hors
    // bornes partirait sinon jusqu'au serveur pour revenir en 23514, que
    // `isDefinitiveSyncError` classe comme définitif.
    if (partnerDebtAlertDays != null) {
      payload['partner_debt_alert_days'] =
          partnerDebtAlertDays.clamp(1, 365);
    }
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

  /// Met à jour `shops.logo_url` (Supabase → Hive). Distinct de
  /// [updateShop] qui ignore les `null` : ici `null` signifie
  /// EXPLICITEMENT « supprimer le logo » (le user a cliqué Supprimer).
  ///
  /// Le bucket Storage `shop_logos` est nettoyé par
  /// `LogoStorageService.deleteLogo` côté caller — cette méthode ne
  /// touche QUE la colonne SQL.
  static Future<void> updateShopLogoUrl(
      String shopId, String? url) async {
    _assertNotFrozen();
    final row = await _db.from('shops').update({'logo_url': url})
        .eq('id', shopId).select().single();
    final updated = _rowToShop(row);
    await LocalStorageService.saveShop(updated);
    _notify('shops', shopId);
    debugPrint('[DB] 🖼  shops.logo_url mis à jour pour $shopId : '
        '${url ?? "<null>"}');
  }

  // ══ SUPER-ADMIN (SA-1 / SA-2) ════════════════════════════════════
  // RPC réservées super-admin (vérif `_is_super_admin()` côté serveur,
  // cf. hotfix_088). On re-pull la ligne shop après pour rafraîchir le
  // cache local (status/suspended_*).

  /// Suspend une boutique (super-admin). [reason] obligatoire (≥ 1 car).
  static Future<void> suspendShop(String shopId, String reason) async {
    await _db.rpc('suspend_shop', params: {
      'p_shop_id': shopId,
      'p_reason':  reason,
    });
    await _refreshShopFromRemote(shopId);
  }

  /// Réactive une boutique suspendue (super-admin).
  static Future<void> reactivateShop(String shopId) async {
    await _db.rpc('reactivate_shop', params: {'p_shop_id': shopId});
    await _refreshShopFromRemote(shopId);
  }

  /// Crée (id null) ou met à jour un plan d'abonnement (super-admin).
  /// Retourne l'id du plan. Les `null` côté serveur conservent la valeur
  /// existante (COALESCE) — on envoie donc explicitement chaque champ.
  static Future<String> upsertPlan({
    String?            id,
    required String    name,
    required String    label,
    required num       priceMonthly,
    required num       priceQuarterly,
    required num       priceYearly,
    required int       maxProducts,
    required int       maxUsersPerShop,
    required int       maxShops,
    required List<String> features,
    required bool      offlineEnabled,
    required int       trialDays,
    required bool      isActive,
    int                maxPartnerDepots    = 0,
    int                maxEmployeesPerShop = 0,
    int                maxWarehouses       = 0,
  }) async {
    final res = await _db.rpc('upsert_plan', params: {
      'p_id':                 id,
      'p_name':               name.trim(),
      'p_label':              label.trim(),
      'p_price_monthly':      priceMonthly,
      'p_price_quarterly':    priceQuarterly,
      'p_price_yearly':       priceYearly,
      'p_max_products':       maxProducts,
      'p_max_users_per_shop': maxUsersPerShop,
      'p_max_shops':          maxShops,
      'p_features':           features,
      'p_offline_enabled':    offlineEnabled,
      'p_trial_days':         trialDays,
      'p_is_active':          isActive,
      'p_max_partner_depots':     maxPartnerDepots,
      'p_max_employees_per_shop': maxEmployeesPerShop,
      'p_max_warehouses':         maxWarehouses,
    });
    return res.toString();
  }

  /// Supprime un plan (super-admin). Échoue si le plan a déjà été utilisé
  /// (RPC delete_plan → désactiver à la place). Voir hotfix_113.
  static Future<void> deletePlan(String id) async {
    await _db.rpc('delete_plan', params: {'p_id': id});
  }

  /// SA-3 — prolonge l'essai/abonnement de l'owner de [shopId] de [days]
  /// jours. Retourne la nouvelle date d'expiration.
  static Future<DateTime?> extendTrial(String shopId, int days) async {
    final res = await _db.rpc('extend_trial', params: {
      'p_shop_id': shopId,
      'p_days':    days,
    });
    return res == null ? null : DateTime.tryParse(res.toString());
  }

  /// DÉMARRE (ou relance) un essai pour le propriétaire de [shopId] — RPC
  /// super-admin `sa_start_trial` (hotfix_135). Marche même sans abonnement
  /// (nouvel essai) ou pour réactiver un essai expiré ; débloque le compte.
  /// Retourne la nouvelle date d'expiration.
  static Future<DateTime?> startTrial(String shopId, int days) async {
    final res = await _db.rpc('sa_start_trial', params: {
      'p_shop_id': shopId,
      'p_days':    days,
    });
    return res == null ? null : DateTime.tryParse(res.toString());
  }

  /// État du MODE GRATUIT GLOBAL (config plateforme, hotfix_136).
  /// `{enabled: bool, until: DateTime?}`. `null` si lecture impossible.
  static Future<({bool enabled, DateTime? until})?> getFreeMode() async {
    try {
      final res = await _db.from('platform_config')
          .select('free_mode_enabled, free_mode_until')
          .eq('id', 1).maybeSingle();
      if (res == null) return null;
      return (
        enabled: res['free_mode_enabled'] == true,
        until: res['free_mode_until'] != null
            ? DateTime.tryParse(res['free_mode_until'].toString())
            : null,
      );
    } catch (_) {
      return null;
    }
  }

  /// SA : active/désactive le MODE GRATUIT GLOBAL — RPC `sa_set_free_mode`.
  /// Quand actif, TOUS les comptes passent en accès Business. Retourne l'état
  /// effectif (true = actif).
  static Future<bool> setFreeMode(bool enabled, {DateTime? until}) async {
    final res = await _db.rpc('sa_set_free_mode', params: {
      'p_enabled': enabled,
      'p_until':   until?.toUtc().toIso8601String(),
    });
    return res == true;
  }

  /// Subscription courante (active/trial) du propriétaire de [shopId].
  /// Lecture directe Supabase (RLS super-admin / owner). `null` si aucune.
  static Future<Map<String, dynamic>?> getShopSubscription(
      String shopId) async {
    try {
      final shop = await _db.from('shops')
          .select('owner_id').eq('id', shopId).single();
      final ownerId = shop['owner_id'];
      if (ownerId == null) return null;
      final rows = await _db.from('subscriptions')
          .select('id, plan_id, sub_status, started_at, expires_at, '
                  'amount_paid, billing_cycle, '
                  'plans!subscriptions_plan_id_fkey(name, label)')
          .eq('user_id', ownerId)
          .inFilter('sub_status', ['active', 'trial'])
          .order('expires_at', ascending: false)
          .limit(1);
      final list = List<Map<String, dynamic>>.from(rows);
      return list.isEmpty ? null : list.first;
    } catch (e) {
      debugPrint('[DB] getShopSubscription: $e');
      return null;
    }
  }

  /// SA-4 — historique des paiements d'une boutique (récent → ancien).
  static Future<List<Map<String, dynamic>>> getShopPayments(
      String shopId) async {
    try {
      final rows = await _db.from('payment_records')
          .select('id, amount, currency, paid_at, method, reference, note, '
                  'plan_id, plans(label)')
          .eq('shop_id', shopId)
          .order('paid_at', ascending: false);
      return List<Map<String, dynamic>>.from(rows);
    } catch (e) {
      debugPrint('[DB] getShopPayments: $e');
      return const [];
    }
  }

  /// SA-4 — enregistre un paiement. [activatePlan] bascule la subscription
  /// de l'owner sur [planId] (active, +[months] mois). Retourne l'id.
  static Future<String> recordPayment({
    required String shopId,
    String?         planId,
    required num    amount,
    String          currency = 'XAF',
    String?         method,
    String?         reference,
    String?         note,
    bool            activatePlan = false,
    int             months = 1,
  }) async {
    final res = await _db.rpc('record_payment', params: {
      'p_shop_id':       shopId,
      'p_plan_id':       planId,
      'p_amount':        amount,
      'p_currency':      currency,
      'p_method':        method,
      'p_reference':     reference,
      'p_note':          note,
      'p_activate_plan': activatePlan,
      'p_months':        months,
    });
    return res.toString();
  }

  /// SA-5 — envoie un broadcast (super-admin). Retourne l'id créé.
  static Future<String> sendBroadcast({
    required String title,
    required String body,
    required String type,         // info | warning | maintenance
    required String targetType,   // all | plan | shop
    String?         targetValue,
  }) async {
    final res = await _db.rpc('send_broadcast', params: {
      'p_title':        title,
      'p_body':         body,
      'p_type':         type,
      'p_target_type':  targetType,
      'p_target_value': targetValue,
    });
    return res.toString();
  }

  /// SA-5 — historique des broadcasts (récent → ancien).
  static Future<List<Map<String, dynamic>>> getBroadcasts() async {
    try {
      final rows = await _db.from('broadcasts')
          .select('id, title, body, type, target_type, target_value, sent_at')
          .order('sent_at', ascending: false)
          .limit(100);
      return List<Map<String, dynamic>>.from(rows);
    } catch (e) {
      debugPrint('[DB] getBroadcasts: $e');
      return const [];
    }
  }

  /// SA-7 — incidents de TOUTES les boutiques (console super-admin).
  /// Lecture autorisée par la policy `incidents_superadmin_read`. Joint
  /// le nom de la boutique. Filtrage (type/boutique/date) côté UI.
  static Future<List<Map<String, dynamic>>> getAllIncidents() async {
    try {
      final rows = await _db.from('incidents')
          .select('id, shop_id, product_name, type, status, severity, '
                  'quantity, created_at, shops(name)')
          .neq('status', 'resolved')
          .order('created_at', ascending: false)
          .limit(500);
      return List<Map<String, dynamic>>.from(rows);
    } catch (e) {
      debugPrint('[DB] getAllIncidents: $e');
      return const [];
    }
  }

  // ── Observabilité (Phase 1) — rapports de bugs vers le SA ──────────────────

  /// Pousse un rapport d'erreur via la RPC `report_error` (dédupliquée côté
  /// serveur). Offline-first : online direct, sinon enqueue dans la file RPC
  /// existante (rejoué au retour réseau). Ne throw jamais.
  static Future<void> reportError(Map<String, dynamic> params) async {
    try {
      if (_i._isOnline) {
        try {
          await _db.rpc('report_error', params: params);
        } catch (_) {
          // Transitoire (réseau) → réessai différé via la file RPC.
          _enqueue({'table': 'rpc', 'op': 'rpc', 'name': 'report_error',
                    'data': params});
        }
      } else {
        _enqueue({'table': 'rpc', 'op': 'rpc', 'name': 'report_error',
                  'data': params});
      }
    } catch (_) {
      // L'observabilité ne doit jamais faire échouer l'appelant.
    }
  }

  /// Lecture des rapports de bugs (réservée super-admin par la policy
  /// `error_reports_sa_read`). Dédupliqués (1 ligne/bug), triés par dernière
  /// occurrence. Exclut les bugs « ignorés ».
  static Future<List<Map<String, dynamic>>> getErrorReports() async {
    try {
      final rows = await _db.from('error_reports')
          .select('id, severity, error_type, message, route, action, '
                  'shop_id, platform, app_version, count, status, '
                  'first_seen_at, last_seen_at, sentry_event_id, stack')
          .neq('status', 'ignored')
          .order('last_seen_at', ascending: false)
          .limit(500);
      return List<Map<String, dynamic>>.from(rows);
    } catch (e) {
      debugPrint('[DB] getErrorReports: $e');
      return const [];
    }
  }

  /// Met à jour le statut d'un rapport (résolu / ignoré / en cours). Gardé
  /// côté serveur par la policy `error_reports_sa_update` (super-admin).
  static Future<void> setErrorReportStatus(String id, String status) async {
    await _db.from('error_reports').update({'status': status}).eq('id', id);
  }

  /// SA-6 — statistiques plateforme (super-admin). Agrégations directes
  /// Supabase. Retourne une map prête pour l'UI :
  ///   revenue, shopsActive, shopsSuspended, shopsTrial,
  ///   salesToday, salesWeek, salesMonth, topShops (5 × {name, total}).
  static Future<Map<String, dynamic>> getPlatformStats() async {
    final out = <String, dynamic>{
      'revenue': 0.0, 'shopsActive': 0, 'shopsSuspended': 0,
      'shopsTrial': 0, 'salesToday': 0, 'salesWeek': 0,
      'salesMonth': 0, 'topShops': <Map<String, dynamic>>[],
    };
    try {
      final shops = List<Map<String, dynamic>>.from(
          await _db.from('shops').select('id, name, status, is_active'));
      final subs = List<Map<String, dynamic>>.from(await _db
          .from('subscriptions')
          .select('amount_paid, sub_status'));
      // Ventes : on récupère orders (id, shop_id, created_at, items) pour
      // le comptage par période + CA par boutique.
      final orders = List<Map<String, dynamic>>.from(await _db
          .from('orders')
          .select('shop_id, created_at, status, deleted_at')
          .filter('deleted_at', 'is', null));

      out['revenue'] = subs.fold<double>(
          0, (a, s) => a + ((s['amount_paid'] as num?)?.toDouble() ?? 0));
      out['shopsActive'] = shops
          .where((s) => s['status'] != 'suspended' && s['is_active'] == true)
          .length;
      out['shopsSuspended'] =
          shops.where((s) => s['status'] == 'suspended').length;
      out['shopsTrial'] =
          subs.where((s) => s['sub_status'] == 'trial').length;

      final now = DateTime.now();
      final todayStart = DateTime(now.year, now.month, now.day);
      final weekStart  = todayStart.subtract(Duration(days: now.weekday - 1));
      final monthStart = DateTime(now.year, now.month, 1);
      int today = 0, week = 0, month = 0;
      final byShop = <String, int>{};
      for (final o in orders) {
        final d = DateTime.tryParse(o['created_at']?.toString() ?? '');
        if (d == null) continue;
        if (d.isAfter(monthStart)) month++;
        if (d.isAfter(weekStart))  week++;
        if (d.isAfter(todayStart)) today++;
        final sid = o['shop_id']?.toString();
        if (sid != null) byShop[sid] = (byShop[sid] ?? 0) + 1;
      }
      out['salesToday'] = today;
      out['salesWeek']  = week;
      out['salesMonth'] = month;

      final nameById = {for (final s in shops) s['id']: s['name']};
      final top = byShop.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      out['topShops'] = [
        for (final e in top.take(5))
          {'name': nameById[e.key] ?? '—', 'count': e.value},
      ];
    } catch (e) {
      debugPrint('[DB] getPlatformStats: $e');
    }
    return out;
  }

  /// SA-8 — récap export plateforme : une ligne par boutique avec
  /// nom, propriétaire, plan, CA encaissé (somme payment_records),
  /// nb de ventes (orders non supprimées) et date de création.
  /// Retourne (header, rows) prêt pour ExportService.
  static Future<(List<String>, List<List<Object?>>)>
      getPlatformShopsExport() async {
    final header = ['Boutique', 'Propriétaire', 'Plan', 'Statut',
        'CA encaissé', 'Nb ventes', 'Créée le'];
    try {
      final shops = List<Map<String, dynamic>>.from(await _db.from('shops')
          .select('id, name, owner_id, status, created_at'));
      final profiles = List<Map<String, dynamic>>.from(await _db
          .from('profiles').select('id, name, email'));
      final subs = List<Map<String, dynamic>>.from(await _db
          .from('subscriptions')
          .select('user_id, sub_status, '
                  'plans!subscriptions_plan_id_fkey(label)'));
      final pays = List<Map<String, dynamic>>.from(await _db
          .from('payment_records').select('shop_id, amount'));
      final orders = List<Map<String, dynamic>>.from(await _db
          .from('orders').select('shop_id, deleted_at')
          .filter('deleted_at', 'is', null));

      final profById = {for (final p in profiles) p['id']: p};
      final planByUser = {
        for (final s in subs)
          if (s['sub_status'] == 'active' || s['sub_status'] == 'trial')
            s['user_id']: (s['plans'] as Map?)?['label'],
      };
      final caByShop = <String, double>{};
      for (final p in pays) {
        final sid = p['shop_id']?.toString();
        if (sid == null) continue;
        caByShop[sid] = (caByShop[sid] ?? 0) + ((p['amount'] as num?)?.toDouble() ?? 0);
      }
      final salesByShop = <String, int>{};
      for (final o in orders) {
        final sid = o['shop_id']?.toString();
        if (sid != null) salesByShop[sid] = (salesByShop[sid] ?? 0) + 1;
      }

      final rows = <List<Object?>>[];
      for (final s in shops) {
        final owner = profById[s['owner_id']];
        final created = DateTime.tryParse(s['created_at']?.toString() ?? '');
        rows.add([
          s['name'] ?? '—',
          owner?['name'] ?? owner?['email'] ?? '—',
          planByUser[s['owner_id']] ?? '—',
          s['status'] == 'suspended' ? 'Suspendue' : 'Active',
          (caByShop[s['id']] ?? 0).toStringAsFixed(0),
          salesByShop[s['id']] ?? 0,
          created != null
              ? '${created.day.toString().padLeft(2, '0')}/'
                '${created.month.toString().padLeft(2, '0')}/${created.year}'
              : '—',
        ]);
      }
      return (header, rows);
    } catch (e) {
      debugPrint('[DB] getPlatformShopsExport: $e');
      return (header, <List<Object?>>[]);
    }
  }

  /// SA-8 — export de TOUS les payment_records (toutes boutiques).
  static Future<(List<String>, List<List<Object?>>)>
      getPlatformPaymentsExport() async {
    final header = ['Date', 'Boutique', 'Montant', 'Devise', 'Mode',
        'Référence', 'Note'];
    try {
      final pays = List<Map<String, dynamic>>.from(await _db
          .from('payment_records')
          .select('amount, currency, paid_at, method, reference, note, '
                  'shops(name)')
          .order('paid_at', ascending: false));
      final rows = <List<Object?>>[];
      for (final p in pays) {
        final d = DateTime.tryParse(p['paid_at']?.toString() ?? '');
        rows.add([
          d != null
              ? '${d.day.toString().padLeft(2, '0')}/'
                '${d.month.toString().padLeft(2, '0')}/${d.year}'
              : '—',
          (p['shops'] as Map?)?['name'] ?? '—',
          (p['amount'] as num?)?.toStringAsFixed(0) ?? '0',
          p['currency'] ?? 'XAF',
          p['method'] ?? '—',
          p['reference'] ?? '',
          p['note'] ?? '',
        ]);
      }
      return (header, rows);
    } catch (e) {
      debugPrint('[DB] getPlatformPaymentsExport: $e');
      return (header, <List<Object?>>[]);
    }
  }

  /// Liste des plans (id, name, label) pour les sélecteurs admin.
  static Future<List<Map<String, dynamic>>> getPlansLite() async {
    try {
      final rows = await _db.from('plans')
          .select('id, name, label, price_monthly')
          .eq('is_active', true)
          .order('sort_order');
      return List<Map<String, dynamic>>.from(rows);
    } catch (e) {
      debugPrint('[DB] getPlansLite: $e');
      return const [];
    }
  }

  /// Re-pull une boutique depuis Supabase → Hive (après une RPC qui modifie
  /// la ligne côté serveur). Best-effort : si offline, l'écho realtime
  /// finira par rafraîchir.
  static Future<void> _refreshShopFromRemote(String shopId) async {
    try {
      final row = await _db.from('shops').select().eq('id', shopId).single();
      final updated = _rowToShop(row);
      await LocalStorageService.saveShop(updated);
      _notify('shops', shopId);
    } catch (e) {
      debugPrint('[DB] _refreshShopFromRemote($shopId) : $e');
    }
  }

  /// Rafraîchit le statut d'une boutique depuis le serveur (status/suspension
  /// inclus) et notifie les écouteurs. Utilisé par le shell pour détecter une
  /// suspension décidée par le super-admin, même en cours de session.
  static Future<void> refreshShop(String shopId) =>
      _refreshShopFromRemote(shopId);

  /// Active / désactive une boutique (Hive immédiat + Supabase background).
  static Future<void> setShopActive(String shopId, bool active) async {
    final cached = LocalStorageService.getShop(shopId);
    if (cached != null) {
      final updated = ShopSummary(
        id: cached.id, name: cached.name, logoUrl: cached.logoUrl,
        currency: cached.currency, country: cached.country,
        sector: cached.sector, isActive: active,
        todaySales: cached.todaySales, ownerId: cached.ownerId,
        phone: cached.phone, whatsappPhone: cached.whatsappPhone,
        email: cached.email,
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
      // Notifier les listeners (ex. currentShopProvider) que les boutiques
      // ont été (re)synchronisées → rafraîchit logo/nom sans actualisation.
      for (final s in shops) { _notify('shops', s.id); }
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
    _assertNotFrozen();
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
    // Capture l'identité PRÉCÉDENTE (avant écrasement) pour répercuter un
    // éventuel changement de nom/image sur les commandes existantes.
    String? prevProdName, prevProdImage;
    final prevRaw = HiveBoxes.productsBox.get(p.id!);
    if (prevRaw != null) {
      final pm = Map<String, dynamic>.from(prevRaw);
      prevProdName  = pm['name']      as String?;
      prevProdImage = pm['image_url'] as String?;
    }
    LocalStorageService.invalidateProductsCache();
    await HiveBoxes.productsBox.put(p.id!, _productToMap(p));
    // Ré-invalidation APRÈS le put : entre l'invalidation pré-put et la fin du
    // `await put`, une lecture concurrente (dashboard / bloc / onboarding)
    // pouvait re-cacher l'état d'AVANT écriture (produit absent). Le `_notify`
    // ci-dessous servait alors ce cache obsolète → le produit fraîchement créé
    // n'apparaissait pas en Caisse (il fallait pull-to-refresh). On revide donc
    // pour que le re-read post-notify relise Hive à jour.
    LocalStorageService.invalidateProductsCache();

    // 3. Notifier les listeners locaux
    if (p.storeId != null) _notify('products', p.storeId!);

    // 3bis. Répercuter un changement d'identité (nom/image) du produit sur
    //       les snapshots des lignes de commande existantes (prix figé).
    _cascadeProductToOrders(p, prevProdName, prevProdImage);

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
  /// Préfixe du flag « réconciliation StockLevel déjà faite » (par boutique).
  static const String _kStockReconcileFlag = '_stocklevel_reconciled_v1_';

  /// Réaligne UNE FOIS (par appareil et par boutique) le StockLevel de la
  /// boutique sur `variant.stockAvailable` pour chaque produit. Corrige les
  /// mouvements PASSÉS (ventes, etc.) où la garde anti-écho avait bloqué la
  /// propagation variante→StockLevel → l'inventaire/grille restaient sur une
  /// valeur périmée. N'écrit QUE les StockLevel réellement divergents (le
  /// `force:true` bypass l'anti-écho, la comparaison interne saute les
  /// identiques) et ne touche JAMAIS les emplacements partenaire/entrepôt.
  /// Cf. project_stocklevel_sync_after_sale.
  static Future<void> _reconcileShopStockLevelsOnce(String shopId) async {
    final key = '$_kStockReconcileFlag$shopId';
    if (HiveBoxes.settingsBox.get(key) == true) return;
    try {
      final products = getProductsForShop(shopId);
      for (final p in products) {
        await _syncShopStockLevelsFromProduct(p, force: true);
      }
      await HiveBoxes.settingsBox.put(key, true);
      _notify('stock_levels', shopId);
      _notify('products', shopId);
      debugPrint('[DB] réconciliation StockLevel OK pour $shopId '
          '(${products.length} produits)');
    } catch (e) {
      debugPrint('[DB] réconciliation StockLevel échouée $shopId: $e');
    }
  }

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

  /// Soft-delete d'un produit (hotfix_085).
  ///
  /// Garde-fous (en miroir de la RPC SQL `delete_product`) :
  ///   1. Stock résiduel > 0 (somme sur variants + stock_levels) → throw
  ///      [ProductNotDeletableException] (compat existant) avec compteurs.
  ///   2. ≥ 1 commande ouverte référence le produit → throw idem.
  ///   3. Motif < 10 caractères → throw [ArgumentError] (le caller — UI
  ///      dialog ou use case — doit valider AVANT d'appeler cette méthode).
  ///
  /// Effets :
  ///   • Hive immédiat : marque `deleted_at / deleted_by / delete_reason`
  ///     + force `is_active = false` et `is_visible_web = false`. La
  ///     ligne reste dans la box (filtrée par `getProductsForShop`).
  ///   • RPC `delete_product` via `bgSoftDeleteProduct` (online direct
  ///     ou enqueue offline + replay au retour réseau).
  ///   • Notifie listeners + invalide le cache produits.
  ///
  /// La RPC serveur capture un `archived_snapshot` que realtime redescend
  /// ensuite dans Hive — la lecture super-admin l'utilise pour l'affichage.
  static Future<void> deleteProduct(String productId, {
    required String reason,
    required String userId,
  }) async {
    _assertNotFrozen();

    // ── 1. Lecture produit + extraction variants (depuis Hive). ───────
    final raw = HiveBoxes.productsBox.get(productId);
    final shopId   = raw is Map ? raw['store_id'] as String? : null;
    final prodName = raw is Map ? (raw['name'] as String? ?? '') : '';
    if (raw is! Map) {
      throw ProductNotDeletableException(
        productName: prodName.isEmpty ? 'ce produit' : prodName);
    }

    final trimmed = reason.trim();
    if (trimmed.length < 10) {
      // Le caller (DeleteProductUseCase / DeleteProductDialog) doit
      // valider le motif AVANT. Cette garde est défensive.
      throw ArgumentError(
          'Motif obligatoire (10 caractères minimum) pour supprimer.');
    }

    final variantIds = <String>{};
    int totalAvailable = 0;
    int totalPhysical  = 0;
    final vars = (raw['variants'] as List?) ?? [];
    for (final v in vars) {
      final vm = Map<String, dynamic>.from(v as Map);
      final vid = vm['id'] as String?;
      if (vid != null && vid.isNotEmpty) variantIds.add(vid);
      totalAvailable += (vm['stockAvailable'] as num?)?.toInt() ?? 0;
      totalPhysical  += (vm['stockPhysical']  as num?)?.toInt() ?? 0;
    }
    // Stock_levels distincts (partenaires / warehouse) — pris en max
    // pour ne pas masquer un stock résiduel non encore répliqué.
    for (final lvlRaw in HiveBoxes.stockLevelsBox.values) {
      try {
        final m = Map<String, dynamic>.from(lvlRaw);
        final vid = m['variant_id'] as String?;
        if (vid == null || !variantIds.contains(vid)) continue;
        final avail = (m['stock_available'] as num?)?.toInt() ?? 0;
        final phys  = (m['stock_physical']  as num?)?.toInt() ?? 0;
        if (avail > totalAvailable) totalAvailable = avail;
        if (phys  > totalPhysical)  totalPhysical  = phys;
      } catch (_) {}
    }

    // ── 2. Commandes ouvertes référençant ce produit ou ses variants.
    //       On EXCLUT les commandes soft-deleted (hotfix_084) — symétrique
    //       avec la RPC SQL.
    int openSalesCount   = 0;
    int totalOrdersCount = 0;
    const openStatuses = {'scheduled', 'processing'};
    for (final orderRaw in HiveBoxes.ordersBox.values) {
      final om = Map<String, dynamic>.from(orderRaw);
      if (om['deleted_at'] != null) continue;
      final items = (om['items'] as List?) ?? [];
      bool referenced = false;
      for (final it in items) {
        final pid = (it as Map)['product_id']?.toString();
        if (pid == productId || variantIds.contains(pid)) {
          referenced = true;
          break;
        }
      }
      if (!referenced) continue;
      totalOrdersCount++;
      final st = om['status'] as String? ?? '';
      if (openStatuses.contains(st)) openSalesCount++;
    }

    final blocked = totalAvailable > 0
        || totalPhysical > 0
        || openSalesCount > 0;

    if (blocked) {
      throw ProductNotDeletableException(
        productName:      prodName.isEmpty ? 'ce produit' : prodName,
        totalAvailable:   totalAvailable,
        totalPhysical:    totalPhysical,
        openSalesCount:   openSalesCount,
        totalOrdersCount: totalOrdersCount,
      );
    }

    // ── 3. Marquage Hive — soft-delete + force is_active / is_visible_web
    //       à false. La ligne reste dans la box (filtrée par les readers).
    final map = Map<String, dynamic>.from(raw);
    map['deleted_at']     = DateTime.now().toUtc().toIso8601String();
    map['deleted_by']     = userId;
    map['delete_reason']  = trimmed;
    map['is_active']      = false;
    map['is_visible_web'] = false;
    LocalStorageService.invalidateProductsCache();
    await HiveBoxes.productsBox.put(productId, map);
    if (shopId != null) _notify('products', shopId);

    // ── 4. Push RPC delete_product (online direct ou enqueue offline).
    await bgSoftDeleteProduct(
      productId: productId,
      userId:    userId,
      reason:    trimmed,
    );
  }

  /// Push de la RPC `delete_product` (hotfix_085). Online → call direct +
  /// rethrow des erreurs métier serveur (P0001/P0002) pour que le caller
  /// puisse rollback Hive ou afficher. Offline → enqueue + retry au
  /// retour réseau. Voir `bgSoftDeleteSale` (hotfix_084) pour la même
  /// philosophie sur les commandes.
  static Future<void> bgSoftDeleteProduct({
    required String productId,
    required String userId,
    required String reason,
  }) async {
    final params = <String, dynamic>{
      'p_product_id': productId,
      'p_user_id':    userId,
      'p_reason':     reason,
    };
    if (_i._isOnline) {
      try {
        await _db.rpc('delete_product', params: params);
      } catch (e) {
        final err = e.toString();
        if (err.contains('P0001') || err.contains('P0002')
            || err.contains('42501')) {
          rethrow;
        }
        _enqueue({'table': 'rpc', 'op': 'rpc', 'name': 'delete_product',
                  'data': params});
      }
    } else {
      _enqueue({'table': 'rpc', 'op': 'rpc', 'name': 'delete_product',
                'data': params});
    }
  }

  /// Restauration d'un produit soft-deleted via la RPC `restore_product`
  /// (hotfix_085). Réservée super-admin (vérification côté SQL). Online
  /// uniquement — pas d'enqueue offline (l'écran restore est super-admin
  /// → suppose une session active). Ne re-publie pas le produit :
  /// `is_active` et `is_visible_web` restent à false côté serveur, le
  /// manager doit republier manuellement.
  static Future<void> bgRestoreProduct({
    required String productId,
    required String userId,
  }) async {
    await _db.rpc('restore_product', params: <String, dynamic>{
      'p_product_id': productId,
      'p_user_id':    userId,
    });
  }

  static List<Product> getProductsForShop(String shopId) =>
      LocalStorageService.getProductsForShop(shopId)
          .where((p) => p.id != null).toList();

  /// Recherche un produit par SKU de variante — **cache Hive uniquement**,
  /// jamais de requête réseau : appelée pendant la frappe (contrôle
  /// d'unicité en direct dans la fiche produit).
  ///
  /// Portée à la BOUTIQUE : la boîte Hive est partagée par toutes les
  /// boutiques du device, et un SKU identique ailleurs n'est pas un conflit.
  /// Sans ce filtre, on signalerait de faux doublons.
  ///
  /// Les produits supprimés (soft-delete) sont ignorés : leur SKU est
  /// réutilisable. On lit les Maps brutes et on ne désérialise qu'au match,
  /// pour ne pas reconstruire tout le catalogue à chaque caractère.
  static Future<Product?> findProductBySku(String shopId, String sku) async {
    final needle = sku.trim().toLowerCase();
    if (needle.isEmpty) return null;
    for (final raw in HiveBoxes.productsBox.values) {
      try {
        final m = Map<String, dynamic>.from(raw);
        if (m['store_id'] != shopId) continue;
        if (m['deleted_at'] != null) continue;
        for (final v in (m['variants'] as List? ?? [])) {
          final s = ((v as Map)['sku'] as String?)?.trim().toLowerCase();
          if (s != null && s == needle) {
            final id = m['id'] as String?;
            return id == null ? null : LocalStorageService.getProduct(id);
          }
        }
      } catch (_) {
        // Ligne illisible (format hérité) : ignorée — elle ne doit pas
        // faire échouer un simple contrôle de saisie.
      }
    }
    return null;
  }

  /// Produits de la boutique dont le nom contient [query] — **cache Hive
  /// uniquement**, jamais le réseau : appelée pendant la frappe.
  ///
  /// Sert à prévenir les doublons au moment de nommer un produit. Portée à
  /// la boutique pour la même raison que [findProductBySku] : la boîte est
  /// partagée par toutes les boutiques de l'appareil. Les produits
  /// supprimés sont ignorés.
  static Future<List<Product>> searchProductsByName(
      String shopId, String query, {int limit = 5}) async {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return const [];
    final out = <Product>[];
    for (final raw in HiveBoxes.productsBox.values) {
      try {
        final m = Map<String, dynamic>.from(raw);
        if (m['store_id'] != shopId) continue;
        if (m['deleted_at'] != null) continue;
        final name = (m['name'] as String?) ?? '';
        if (!name.toLowerCase().contains(needle)) continue;
        final id = m['id'] as String?;
        if (id == null) continue;
        final p = LocalStorageService.getProduct(id);
        if (p != null) out.add(p);
        if (out.length >= limit) break;
      } catch (_) {
        // Ligne illisible (format hérité) : ignorée — elle ne doit pas
        // faire échouer une simple suggestion de saisie.
      }
    }
    return out;
  }

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

  /// Crée (ou récupère) la location type='shop' pour une boutique, ET
  /// la (re-)pousse vers Supabase à CHAQUE appel (upsert idempotent).
  ///
  /// Le re-push systématique répare automatiquement le cas où un push
  /// précédent a échoué (RLS, FK, schema_version legacy, abandon après
  /// 10 retries, etc.) : la StockLocation existait alors en Hive mais
  /// PAS sur Supabase, bloquant tous les `stock_transfers` /
  /// `stock_levels` qui la référencent (erreurs FK 23503 + RLS 42501).
  /// Désormais chaque appel auto-répare ce drift silencieusement.
  static StockLocation _ensureShopLocation({
    required String shopId,
    required String ownerId,
    required String shopName,
  }) {
    final locId = _shopLocationId(shopId);
    final existing = HiveBoxes.stockLocationsBox.get(locId);
    StockLocation loc;
    if (existing != null) {
      loc = StockLocation.fromMap(Map<String, dynamic>.from(existing));
    } else {
      loc = StockLocation(
        id: locId,
        ownerId: ownerId,
        type: StockLocationType.shop,
        name: shopName,
        shopId: shopId,
        createdAt: DateTime.now(),
      );
      HiveBoxes.stockLocationsBox.put(locId, loc.toMap());
    }
    // Push idempotent à chaque appel — voir doc ci-dessus.
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
    _assertNotFrozen();
    await HiveBoxes.stockLocationsBox.put(loc.id, loc.toMap());
    _bgWrite({'table': 'stock_locations', 'op': 'upsert', 'data': loc.toMap()});
    _notify('stock_locations', loc.shopId ?? loc.ownerId);
  }

  static Future<void> deleteStockLocation(String locId) async {
    _assertNotFrozen();
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
    _assertNotFrozen();
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
    _assertNotFrozen();
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

    final shop = LocalStorageService.getShop(shopId);
    if (shop == null) return;
    final ownerId = shop.ownerId ?? _userId ?? '';
    if (ownerId.isEmpty) return;

    // 1. Garantir la location type='shop' côté Hive (idempotent — vérifie
    //    l'existant dans Hive avant de créer).
    //    _ensureShopLocation pousse aussi via _bgWrite (queue+strip) à
    //    chaque appel, donc même si le flag de migration est posé, la
    //    location se re-pousse vers Supabase. Auto-répare le drift Hive↔
    //    Supabase causé par un push raté antérieur (schema_version legacy,
    //    RLS transitoire, etc.) sans avoir à reset le flag manuellement.
    final location = _ensureShopLocation(
      shopId:   shopId,
      ownerId:  ownerId,
      shopName: shop.name,
    );

    // Flag déjà posé → les étapes 2-5 (push levels, etc.) ont déjà tourné
    // avec succès dans une session précédente. On a déjà re-poussé la
    // location ci-dessus pour auto-réparer, on peut sortir.
    if (HiveBoxes.settingsBox.get(flagKey) == true) return;

    // 2. Pousser la location Supabase en AWAITANT (requis avant les levels)
    // Strip `schema_version` : le pattern de versioning est purement local
    // (Hive). Les tables Supabase n'ont pas cette colonne — sans ce strip,
    // l'upsert direct échoue en PostgrestException et le flag n'est jamais
    // posé → migration boucle en échec silencieux.
    final locMap = location.toMap()..remove('schema_version');
    if (_i._isOnline) {
      try {
        await _db.from('stock_locations').upsert(locMap)
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
        'data': locMap});
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
    _assertNotFrozen();
    if (!Hive.isBoxOpen(HiveBoxes.expenses)) return;
    final map = _expenseToMap(e);
    await HiveBoxes.expensesBox.put(e.id, map);
    _notify('expenses', e.shopId);
    _bgWrite({'table': 'expenses', 'op': 'upsert', 'data': _expenseToSupabase(e)});
  }

  /// Supprimer une dépense (Hive + Supabase).
  static Future<void> deleteExpense(String id, String shopId) async {
    _assertNotFrozen();
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
      // Même garde que pour les commandes : une dépense créée hors ligne est
      // absente du serveur sans être périmée. La purger la perd sans trace.
      final pendingExpenseIds = _pendingIdsFor('expenses');
      final staleKeys = <dynamic>[];
      for (final key in HiveBoxes.expensesBox.keys) {
        final raw = HiveBoxes.expensesBox.get(key);
        if (raw is! Map) continue;
        if (raw['shop_id']?.toString() != shopId) continue;
        final ks = key.toString();
        if (pendingExpenseIds.contains(ks)) continue;
        if (!remoteIds.contains(ks)) staleKeys.add(key);
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
      // Garde-fou anti-perte : on ne purge JAMAIS une ligne dont une
      // écriture (insert/upsert) est encore en attente dans la file
      // offline. Sans ça, une entrée créée localement mais pas encore
      // confirmée côté Supabase (push async lent, rechargement web avant
      // flush, reconnexion) serait effacée définitivement → perte de
      // données financière silencieuse (bug solde partenaire qui revient).
      // ⚠ ANGLE MORT CONNU, non traité ici (périmètre : ~25 tables passent par
      // cette fonction). Ce filtre ignore les ops `update` et ne lit que
      // `data['id']` — or une op `update` porte son identifiant dans
      // `match['id']`. Une mutation partielle en vol n'est donc PAS protégée
      // de la purge sur ces tables.
      //
      // `_pendingIdsFor` (plus haut) couvre les deux cas et sert déjà
      // `syncOrders` / `syncExpenses`. Le généraliser ici toucherait toutes
      // les tables passthrough d'un coup → reporté en vague 4.
      final pendingIds = <String>{};
      try {
        for (final raw in HiveBoxes.offlineQueueBox.values) {
          if (raw is! Map) continue;
          if (raw['table']?.toString() != tableName) continue;
          final opType = raw['op']?.toString();
          if (opType != 'insert' && opType != 'upsert') continue;
          final d = raw['data'];
          if (d is Map && d['id'] != null) {
            pendingIds.add(d['id'].toString());
          }
        }
      } catch (_) {/* best effort — en cas de doute on ne purge pas */}

      // Garde-fou n°2 (web surtout) : un push ONLINE ne passe PAS par la
      // file offline (_bgWrite exécute direct), donc pendingIds ne le voit
      // pas pendant que le push est en vol. Pour le livre partenaire
      // (financier), on protège en plus toute entrée marquée localement
      // récemment via markLocalLedgerWrite (TTL 24 h, persisté).
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final ledgerEchoGuard = tableName == 'partner_ledger_entries';

      // Purge : supprimer les lignes Hive de ce shop absentes distant,
      // SAUF celles dont le push est encore en file (pendingIds) ou
      // marquées comme écrites localement récemment (echo livre partenaire).
      final staleKeys = <dynamic>[];
      for (final key in box.keys) {
        final raw = box.get(key);
        if (raw is! Map) continue;
        if (raw[shopIdColumn]?.toString() != shopId) continue;
        final ks = key.toString();
        if (pendingIds.contains(ks)) continue;
        if (ledgerEchoGuard) {
          final recentMs = _i._recentLocalLedgerWrites[ks];
          if (recentMs != null && nowMs - recentMs < _kLedgerEchoTtlMs) {
            continue;
          }
        }
        if (!remoteIds.contains(ks)) staleKeys.add(key);
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
          if (tableName == 'partner_ledger_entries') {
            // Suppression douce propagée depuis un autre appareil :
            // `deleted_at` renseigné → retirer du Hive (et de l'affichage)
            // + tombstone durable pour bloquer tout re-push local.
            final del = p.newRecord['deleted_at'];
            if (del != null && del.toString().isNotEmpty) {
              await box.delete(id);
              await markLedgerDeletionPending(id);
              break;
            }
            // Anti-résurrection : entrée supprimée localement (tombstone)
            // ne doit pas être ré-insérée par un echo / re-push obsolète.
            if (_isLedgerDeletionPending(id)) return;
          }
          await box.put(id, Map<String, dynamic>.from(p.newRecord));
        case PostgresChangeEvent.delete:
          final id = p.oldRecord['id']?.toString();
          if (id != null) {
            await box.delete(id);
            // Suppression venue d'un autre appareil → tombstone durable
            // ici aussi, pour que `syncPartnerLedger` ne la re-pousse pas.
            if (tableName == 'partner_ledger_entries') {
              await markLedgerDeletionPending(id);
            }
          }
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
  /// Sync des zones + quartiers de livraison (frais par quartier). Passthrough
  /// simple filtré par `shop_id` (offline-first : dispos en Hive sans réseau).
  static Future<void> syncDeliveryZones(String shopId) =>
      _syncTablePassthrough(tableName: 'delivery_zones',
          shopId: shopId, box: HiveBoxes.deliveryZonesBox);
  static Future<void> syncDeliveryQuartiers(String shopId) =>
      _syncTablePassthrough(tableName: 'delivery_quartiers',
          shopId: shopId, box: HiveBoxes.deliveryQuartiersBox);
  /// Sync du plan de salle restaurant (hotfix_137). Passthrough filtré par
  /// `shop_id`. Trié par `number` et non `created_at` : le plan de salle est
  /// ordonné par numéro de table, et la limite de 500 doit donc conserver les
  /// premières tables si une boutique en déclarait un très grand nombre.
  static Future<void> syncRestaurantTables(String shopId) =>
      _syncTablePassthrough(tableName: 'restaurant_tables',
          shopId: shopId, box: HiveBoxes.restaurantTablesBox,
          orderBy: 'number');
  // ── Module finances restaurant (PR-A) ──────────────────────────────────
  static Future<void> syncIngredients(String shopId) =>
      _syncTablePassthrough(tableName: 'ingredients',
          shopId: shopId, box: HiveBoxes.ingredientsBox);

  static Future<void> syncRecipeIngredients(String shopId) =>
      _syncTablePassthrough(tableName: 'recipe_ingredients',
          shopId: shopId, box: HiveBoxes.recipeIngredientsBox);

  // ── Finances restaurant (PR-B) ─────────────────────────────────────────
  static Future<void> syncRestaurantActivities(String shopId) =>
      _syncTablePassthrough(tableName: 'restaurant_activities',
          shopId: shopId, box: HiveBoxes.restaurantActivitiesBox);

  static Future<void> syncStockItems(String shopId) =>
      _syncTablePassthrough(tableName: 'stock_items',
          shopId: shopId, box: HiveBoxes.stockItemsBox);

  // ── Finances restaurant (PR-C) ─────────────────────────────────────────
  static Future<void> syncFixedCharges(String shopId) =>
      _syncTablePassthrough(tableName: 'fixed_charges',
          shopId: shopId, box: HiveBoxes.fixedChargesBox);

  static Future<void> syncLosses(String shopId) =>
      _syncTablePassthrough(tableName: 'losses',
          shopId: shopId, box: HiveBoxes.lossesBox);

  // ── Règlements d'addition (Lot A restaurant — hotfix_145) ──────────────
  static Future<void> syncPayments(String shopId) =>
      _syncTablePassthrough(tableName: 'payments',
          shopId: shopId, box: HiveBoxes.paymentsBox);

  // ── Consignes d'emballages (Lot B restaurant — hotfix_146) ─────────────
  static Future<void> syncBottleDeposits(String shopId) =>
      _syncTablePassthrough(tableName: 'bottle_deposits',
          shopId: shopId, box: HiveBoxes.bottleDepositsBox);

  // ── Clôtures de caisse X/Z (Lot C restaurant — hotfix_147) ─────────────
  static Future<void> syncCashClosures(String shopId) =>
      _syncTablePassthrough(tableName: 'cash_closures',
          shopId: shopId, box: HiveBoxes.cashClosuresBox,
          orderBy: 'closed_at');

  // ── Personnel restaurant (Lot D — hotfix_148) ──────────────────────────
  static Future<void> syncStaff(String shopId) =>
      _syncTablePassthrough(tableName: 'employees',
          shopId: shopId, box: HiveBoxes.employeesBox);

  static Future<void> syncTimeRecords(String shopId) =>
      _syncTablePassthrough(tableName: 'time_records',
          shopId: shopId, box: HiveBoxes.timeRecordsBox,
          orderBy: 'clock_in');

  static Future<void> syncSalaryAdvances(String shopId) =>
      _syncTablePassthrough(tableName: 'salary_advances',
          shopId: shopId, box: HiveBoxes.salaryAdvancesBox);

  static Future<void> syncPayroll(String shopId) =>
      _syncTablePassthrough(tableName: 'payroll',
          shopId: shopId, box: HiveBoxes.payrollBox);

  // ── Tenue de l'équipe (hotfix_165) ─────────────────────────────────────
  //
  // Casse, notation et primes spéciales. Chacune est isolée : tant que le SQL
  // n'est pas appliqué, la table n'existe pas (42P01) et sa synchro échoue —
  // elle ne doit pas emporter avec elle le personnel et la paie, qui eux
  // fonctionnent depuis hotfix_148.

  static Future<void> syncStaffPenalties(String shopId) =>
      _syncTablePassthrough(tableName: 'staff_penalties',
          shopId: shopId, box: HiveBoxes.staffPenaltiesBox,
          orderBy: 'incident_date');

  static Future<void> syncStaffRatings(String shopId) =>
      _syncTablePassthrough(tableName: 'staff_ratings',
          shopId: shopId, box: HiveBoxes.staffRatingsBox);

  static Future<void> syncStaffContests(String shopId) =>
      _syncTablePassthrough(tableName: 'staff_contests',
          shopId: shopId, box: HiveBoxes.staffContestsBox,
          orderBy: 'end_date');

  // ── Absences décidées : mise à pied, congé payé (hotfix_166) ───────────
  static Future<void> syncStaffAbsences(String shopId) =>
      _syncTablePassthrough(tableName: 'staff_absences',
          shopId: shopId, box: HiveBoxes.staffAbsencesBox,
          orderBy: 'start_date');

  // ── Dépenses quotidiennes (Lot E restaurant — hotfix_149) ──────────────
  static Future<void> syncDailyExpenses(String shopId) =>
      _syncTablePassthrough(tableName: 'daily_expenses',
          shopId: shopId, box: HiveBoxes.dailyExpensesBox,
          orderBy: 'expense_date');
  /// Sync des transferts de commandes vers livreurs/partenaires (hotfix_049).
  /// Utilisé par le filtre dashboard / commandes / finances pour scoper aux
  /// commandes assignées à un partenaire spécifique.
  static Future<void> syncDeliveryTransfers(String shopId) =>
      _syncTablePassthrough(tableName: 'delivery_transfers',
          shopId: shopId, box: HiveBoxes.deliveryTransfersBox);
  /// Sync du livre de comptes partenaires — FUSION-SEULE + RE-PUSH.
  ///
  /// Contrairement aux autres tables passthrough, le livre partenaire est
  /// financier et append-only : on NE PURGE PAS les lignes locales absentes
  /// du serveur (une purge a déjà causé la perte du solde). À la place :
  ///   1. pull serveur → écrit dans Hive ;
  ///   2. RE-PUSH (upsert idempotent) vers Supabase toute entrée locale de
  ///      ce shop absente du serveur → auto-réparation des entrées bloquées
  ///      par un échec de push passé (cas « mobile rempli, serveur à 3 »).
  /// Les suppressions inter-appareils restent propagées par le callback
  /// realtime DELETE (`_onTablePassthroughChange`) et `deleteEntry`.
  /// Compromis assumé : une entrée supprimée sur un autre appareil pendant
  /// que celui-ci était hors-ligne (et a manqué l'event realtime) peut être
  /// re-poussée — acceptable vs perte d'écriture financière.
  static Future<void> syncPartnerLedger(String shopId) async {
    try {
      final box = HiveBoxes.partnerLedgerBox;
      if (!box.isOpen) return;
      final session = _db.auth.currentSession;
      if (session == null) return;
      final rows = await _db.from('partner_ledger_entries')
          .select()
          .eq('shop_id', shopId)
          .order('created_at', ascending: false)
          .limit(1000)
          .timeout(const Duration(seconds: 10));
      final list = rows as List;
      final remoteIds = <String>{};
      for (final row in list) {
        final id = row['id']?.toString();
        if (id == null) continue;
        remoteIds.add(id);
        // Suppression douce serveur : si `deleted_at` est renseigné,
        // l'entrée est supprimée → on la retire du Hive local (et donc
        // de l'affichage) au lieu de la stocker. Convergence multi-
        // appareils garantie sans résurrection.
        final del = row['deleted_at'];
        if (del != null && del.toString().isNotEmpty) {
          await box.delete(id);
          continue;
        }
        // Tombstone local encore actif (suppression in-flight) → ne pas
        // ré-afficher le temps que le `deleted_at` se propage.
        if (_isLedgerDeletionPending(id)) continue;
        await box.put(id, Map<String, dynamic>.from(row));
      }
      // Re-push des entrées locales manquantes côté serveur (idempotent).
      // Skip les tombstones : une entrée supprimée ne doit JAMAIS être
      // re-poussée (sinon résurrection dans le modèle fusion-seule).
      var pushed = 0;
      for (final key in box.keys) {
        final raw = box.get(key);
        if (raw is! Map) continue;
        if (raw['shop_id']?.toString() != shopId) continue;
        final id = key.toString();
        if (remoteIds.contains(id)) continue;
        if (_isLedgerDeletionPending(id)) continue;
        bgUpsert('partner_ledger_entries',
            Map<String, dynamic>.from(raw));
        pushed++;
      }
      debugPrint('[DB] syncPartnerLedger: $shopId '
          '(${list.length} remote, $pushed re-push local→serveur)');
      _notify('partner_ledger_entries', shopId);
    } catch (e) {
      debugPrint('[DB] syncPartnerLedger ERROR: $e');
    }
  }

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
          // Suppression douce serveur — PRIORITAIRE sur tout (y compris la
          // fenêtre d'écho) : une commande marquée `deleted_at` doit QUITTER
          // le Hive. Sans ça, l'écho realtime du RPC `delete_sale` réécrivait
          // la commande en active (le hiveMap ci-dessous n'inclut pas
          // deleted_at) → la suppression « ne réagissait pas » avant un
          // refresh manuel (seul syncOrders honorait deleted_at). Symétrique
          // de syncOrders.
          if (p.newRecord['deleted_at'] != null) {
            await HiveBoxes.ordersBox.delete(id);
            _notify('orders', shopId);
            return;
          }
          // Anti-écho temporel : on vient d'écrire localement, l'event
          // realtime peut être le nôtre (OK, valeur identique) OU un
          // snapshot pré-update arrivé après notre commit (KO, écrase
          // notre nouvel état). Pendant la fenêtre, on garde la version
          // locale ; au-delà on accepte les events (sync inter-device).
          final recentMs = _recentLocalOrderWrites[id];
          if (recentMs != null) {
            final age = DateTime.now().millisecondsSinceEpoch - recentMs;
            if (age < _localWriteEchoWindowMs) {
              debugPrint('[DB] ⏭️ _onOrderChange écho ${age}ms order=$id');
              return;
            }
          }
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
            // Le motif suit le montant. `syncOrders` et `_onOrderChange`
            // reconstruisent cette carte À LA MAIN : un champ ajouté dans un
            // seul des deux revient à chaque resync dans un état, et dans
            // l'autre au suivant.
            'discount_reason': row['discount_reason'],
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
            'delivery_quartier':    row['delivery_quartier'],
            'delivery_zone':        row['delivery_zone'],
            'delivery_price':       row['delivery_price'],
            'shipment_city':        row['shipment_city'],
            'shipment_agency':      row['shipment_agency'],
            'shipment_handler':     row['shipment_handler'],
            'cancellation_reason':  row['cancellation_reason'],
            'reschedule_reason':    row['reschedule_reason'],
            'created_by_user_id':   row['created_by_user_id'],
            'items':          row['items'] ?? [],
            'fees':           row['fees'] ?? [],
            'source':         row['source'] ?? 'pos',
            // Suivi paiement (hotfix_065) — cf. syncOrders pour le même
            // raisonnement : sans ces 2 lignes, un push realtime
            // écraserait localement amount_paid/payment_status.
            'amount_paid':    row['amount_paid'] ?? 0,
            'payment_status': row['payment_status'] ?? 'unpaid',
            // Vente « à choisir sur place » (hotfix_116) — cf. syncOrders :
            // sans ces 2 lignes, un push realtime écrasait le flag local et
            // le badge « À choisir » disparaissait après synchronisation.
            'is_approval_sale': row['is_approval_sale'] ?? false,
            'stock_reserved':   row['stock_reserved'] ?? false,
            // GF-1 (hotfix_080) — cf. syncOrders : préserver la clé sur les
            // events realtime, sinon un update distant l'efface en Hive.
            'idempotency_key': row['idempotency_key'],
            // Jeton de suivi (hotfix_171) — MEME RAISON : généré côté serveur,
            // il n'existe en local que par ce pull. L'omettre ici le remettrait
            // à null au premier event realtime, et le lien WhatsApp retomberait
            // sur l'identifiant, c'est-à-dire sur la fuite qu'on vient de fermer.
            'tracking_token':  row['tracking_token'],
            // Module restaurant (hotfix_137) — MEME RAISON que les 2 blocs
            // ci-dessus : ce hiveMap REMPLACE integralement la ligne locale
            // (put, pas de merge). Sans ces cles, chaque pull/push realtime
            // remettrait la table a libre et viderait l'ecran Cuisine.
            'table_id':        row['table_id'],
            'tab_label':       row['tab_label'],
            'covers':          row['covers'],
            'order_type':      row['order_type'] ?? 'takeaway',
            'sent_to_kitchen': row['sent_to_kitchen'] ?? false,
            'kitchen_ready':   row['kitchen_ready'] ?? false,
            'served':          row['served'] ?? false,
            'finished':        row['finished'] ?? false,
            // Soft-delete (hotfix_084) — symétrie avec _mapToSaleWithStatus.
            'deleted_at':    row['deleted_at'],
            'deleted_by':    row['deleted_by'],
            'delete_reason': row['delete_reason'],
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
      final oldStatus = (p.oldRecord['status'] as String?) ?? '';
      _notifyOrderStatusTransition(shopId, id, row, oldStatus, status);
    }
  }

  /// Émet la cloche pour une TRANSITION de statut de commande. Appelée :
  ///   * depuis le callback realtime `_emitOrderNotification` (UPDATE) ;
  ///   * depuis `syncOrders` (rattrapage) — indispensable quand le client
  ///     valide pendant que l'app est en arrière-plan : le websocket
  ///     realtime est suspendu par le navigateur et l'event est PERDU ;
  ///     le re-sync au retour de l'app (onAppResumed) le détecte par diff
  ///     du statut Hive et déclenche la notif manquée.
  ///
  /// Inclut la validation client `scheduled → processing` (lien de suivi),
  /// qui n'était couverte par AUCUN cas auparavant → aucune cloche.
  /// Idempotent côté NotificationService (dédup 60 s + id par catégorie),
  /// donc realtime + resync sur le même event ne double-notifient pas.
  void _notifyOrderStatusTransition(String shopId, String id,
      Map<String, dynamic> row, String oldStatus, String newStatus) {
    if (oldStatus == newStatus) return;
    if (!NotificationService.enabledForCurrentUser.value) return;
    if (!_isAdminOrOwner(shopId)) return;
    final clientName = (row['client_name'] as String?)?.trim() ?? '';
    final shortId = id.length > 6 ? id.substring(0, 6).toUpperCase() : id;
    final who = clientName.isEmpty ? '—' : clientName;
    switch (newStatus) {
      case 'processing':
        NotificationService.notify(
          kind:    NotifKind.orderValidated,
          title:   'Commande validée par le client',
          message: '#$shortId · $who',
          shopId:   shopId,
          targetId: id,
        );
        break;
      case 'completed':
        NotificationService.notify(
          kind:    NotifKind.orderCompleted,
          title:   'Commande terminée',
          message: '#$shortId · $who',
          shopId:   shopId,
          targetId: id,
        );
        break;
      case 'cancelled':
        NotificationService.notify(
          kind:    NotifKind.orderCancelled,
          title:   'Commande annulée',
          message: '#$shortId · $who',
          shopId:   shopId,
          targetId: id,
        );
        break;
      case 'rejected':
      case 'refused':
        NotificationService.notify(
          kind:    NotifKind.orderRejected,
          title:   'Commande rejetée',
          message: '#$shortId · $who',
          shopId:   shopId,
          targetId: id,
        );
        break;
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
  // Schema versioning — cf. lib/core/storage/schema_migrator.dart.
  static final _expenseMigrator = SchemaMigrator(
    currentVersion: 1, steps: const {});

  static Map<String, dynamic> _expenseToMap(Expense e) => {
    'schema_version': _expenseMigrator.currentVersion,
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
    'location_id':    e.locationId,
  };

  static Map<String, dynamic> _expenseToSupabase(Expense e) =>
      _expenseToMap(e); // mêmes colonnes

  static Expense _expenseFromMap(Map<String, dynamic> rawM) {
    final m = _expenseMigrator.migrate(rawM);
    return Expense(
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
      locationId: m['location_id'] as String?,
    );
  }

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
    'location_id':    row['location_id'],
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
        // Suppression douce serveur : si la commande est marquée `deleted_at`
        // côté Supabase, on la RETIRE du Hive local au lieu de la réécrire en
        // active — sinon le pull « ressuscitait » une commande supprimée
        // (le hiveMap ci-dessous n'inclut pas deleted_at). Symétrique du
        // handler realtime (« deleted_at renseigné → retirer du Hive »).
        if (row['deleted_at'] != null) {
          await HiveBoxes.ordersBox.delete(id);
          continue; // pas ajoutée à remoteIds → reste supprimée localement
        }
        remoteIds.add(id);
        // Statut local AVANT écrasement — sert à détecter une transition
        // survenue à distance (ex. client qui valide via le lien de suivi
        // pendant que l'app était en arrière-plan : l'event realtime a été
        // perdu, ce diff le rattrape et déclenche la cloche manquée).
        final prevRaw = HiveBoxes.ordersBox.get(id);
        final prevStatus =
            (prevRaw is Map) ? prevRaw['status']?.toString() : null;
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
          // Le second des deux chemins — voir `syncOrders`.
          'discount_reason': row['discount_reason'],
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
          'delivery_quartier':    row['delivery_quartier'],
          'delivery_zone':        row['delivery_zone'],
          'delivery_price':       row['delivery_price'],
          'shipment_city':        row['shipment_city'],
          'shipment_agency':      row['shipment_agency'],
          'shipment_handler':     row['shipment_handler'],
          'cancellation_reason':  row['cancellation_reason'],
          'reschedule_reason':    row['reschedule_reason'],
          'created_by_user_id':   row['created_by_user_id'],
          'items':          row['items'] ?? [],
          'fees':           row['fees'] ?? [],
          'source':         row['source'] ?? 'pos',
          // Suivi paiement (hotfix_065). Sans ces 2 lignes, le pull
          // Supabase écrasait la valeur Hive locale (acompte / paid
          // → unpaid 0) à chaque refresh navigateur.
          'amount_paid':    row['amount_paid'] ?? 0,
          'payment_status': row['payment_status'] ?? 'unpaid',
          // Vente « à choisir sur place » (hotfix_116). Sans ces 2 lignes, le
          // pull Supabase écrasait le flag local → le badge « À choisir »
          // disparaissait à chaque actualisation ET le garde-fou anti-double-
          // comptage stock (stock_reserved) était perdu.
          'is_approval_sale': row['is_approval_sale'] ?? false,
          'stock_reserved':   row['stock_reserved'] ?? false,
          // GF-1 (hotfix_080). saveOrder écrit déjà idempotency_key en Hive,
          // mais sans cette ligne le pull Supabase l'écrasait à null à chaque
          // refresh → garde-fou anti-doublon perdu après synchronisation.
          'idempotency_key': row['idempotency_key'],
          // Jeton de suivi (hotfix_171). Généré par le SERVEUR : ce pull est le
          // seul chemin par lequel il arrive en local. Sans cette ligne, il
          // serait écrasé à null à chaque synchronisation et le lien WhatsApp
          // retomberait sur l'identifiant — la fuite qu'on vient de fermer.
          'tracking_token':  row['tracking_token'],
          // Module restaurant (hotfix_137) — MEME RAISON que les 2 blocs
          // ci-dessus : ce hiveMap REMPLACE integralement la ligne locale
          // (put, pas de merge). Sans ces cles, chaque pull/push realtime
          // remettrait la table a libre et viderait l'ecran Cuisine.
          'table_id':        row['table_id'],
          'tab_label':       row['tab_label'],
          'covers':          row['covers'],
          'order_type':      row['order_type'] ?? 'takeaway',
          'sent_to_kitchen': row['sent_to_kitchen'] ?? false,
          'kitchen_ready':   row['kitchen_ready'] ?? false,
          'served':          row['served'] ?? false,
          'finished':        row['finished'] ?? false,
          // Soft-delete (hotfix_084) — symétrie avec _mapToSaleWithStatus.
          // NB : une commande deleted_at != null est déjà retirée du Hive plus
          // haut, donc ces 3 champs sont en pratique toujours null ici ;
          // explicites pour aligner le format d'écriture sur celui de lecture.
          'deleted_at':    row['deleted_at'],
          'deleted_by':    row['deleted_by'],
          'delete_reason': row['delete_reason'],
        };
        await HiveBoxes.ordersBox.put(id, hiveMap);
        // Notif de rattrapage si le statut a changé depuis le dernier état
        // local connu. `prevStatus == null` (commande inconnue jusque-là)
        // → pas de notif transition (évite de sonner pour tout l'historique
        // au premier chargement). La dédup NotificationService empêche le
        // double avec un éventuel event realtime du même changement.
        if (prevStatus != null) {
          final newStatus =
              (hiveMap['status'] as String?) ?? 'scheduled';
          _i._notifyOrderStatusTransition(
              shopId, id, Map<String, dynamic>.from(row),
              prevStatus, newStatus);
        }
      }
      // Diff purge : supprimer les commandes locales de ce shop
      // qui ne sont plus distantes.
      // Garde anti-perte : on ne purge JAMAIS une commande dont l'écriture
      // est encore en file. Absente du serveur ≠ périmée — elle peut n'avoir
      // simplement pas encore été poussée (création hors ligne, push en vol,
      // rechargement web avant flush). Sans cette garde, `onAppResumed`
      // pouvait effacer une vente jamais parvenue au serveur.
      final pendingOrderIds = _pendingIdsFor('orders');
      final staleKeys = <dynamic>[];
      for (final key in HiveBoxes.ordersBox.keys) {
        final raw = HiveBoxes.ordersBox.get(key);
        if (raw is! Map) continue;
        if (raw['shop_id']?.toString() != shopId) continue;
        final ks = key.toString();
        if (pendingOrderIds.contains(ks)) continue;
        if (!remoteIds.contains(ks)) staleKeys.add(key);
      }
      for (final k in staleKeys) {
        await HiveBoxes.ordersBox.delete(k);
      }
      debugPrint('[DB] syncOrders: ${rowList.length} remote, '
          '${staleKeys.length} purgés');
      // Rattrapage : aligne le snapshot client_name/phone des commandes sur
      // les coordonnées actuelles de leur client (historique périmé + dérive).
      _reconcileOrderClientCoords(shopId);
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

  /// Rattrapage : aligne le snapshot figé `client_name`/`client_phone` de
  /// chaque commande en cache sur les coordonnées ACTUELLES de son client.
  ///
  /// Appelé en fin de [syncOrders], après le pull serveur. Ne fait du travail
  /// que s'il existe une divergence → no-op une fois tout aligné (converge en
  /// 1-2 syncs, sans flag de migration). Couvre l'historique périmé avant
  /// l'introduction de la cascade [_cascadeClientCoordsToOrders] ET toute
  /// dérive future (commande créée sur un autre appareil avec un client
  /// modifié depuis). Un seul `UPDATE` serveur par client divergent corrige
  /// toutes ses commandes, y compris celles hors du cache local.
  static void _reconcileOrderClientCoords(String shopId) {
    // Index des coordonnées clients de la boutique.
    final coords = <String, ({String? name, String? phone})>{};
    for (final raw in HiveBoxes.clientsBox.values) {
      final m = Map<String, dynamic>.from(raw);
      if (m['store_id'] != shopId) continue;
      final id = m['id'] as String?;
      if (id == null) continue;
      coords[id] = (name: m['name'] as String?, phone: m['phone'] as String?);
    }
    if (coords.isEmpty) return;

    final drifted = <String>{};
    for (final key in HiveBoxes.ordersBox.keys) {
      final raw = HiveBoxes.ordersBox.get(key);
      if (raw == null) continue;
      final m = Map<String, dynamic>.from(raw);
      if (m['shop_id'] != shopId) continue;
      final cid = m['client_id'] as String?;
      if (cid == null) continue;
      final cur = coords[cid];
      if (cur == null) continue; // client archivé/supprimé : on n'y touche pas
      if (m['client_name'] == cur.name && m['client_phone'] == cur.phone) {
        continue;
      }
      m['client_name']  = cur.name;
      m['client_phone'] = cur.phone;
      HiveBoxes.ordersBox.put(key, m);
      drifted.add(cid);
    }

    for (final cid in drifted) {
      final cur = coords[cid]!;
      _bgWrite({
        'table': 'orders',
        'op':    'update',
        'data':  {'client_name': cur.name, 'client_phone': cur.phone},
        'match': {'client_id': cid, 'shop_id': shopId},
      });
    }
  }

  // ══ CATÉGORIES / MARQUES / UNITÉS ═════════════════════════════════

  static Future<void> saveCategory(String shopId, String name) async {
    _assertNotFrozen();
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
    _assertNotFrozen();
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
    // Rafraîchir les écrans (grille caisse / inventaire) après le renommage.
    if (used > 0) {
      LocalStorageService.invalidateProductsCache();
      _notify('products', shopId);
    }
    await ActivityLogService.log(
      action: 'category_updated', targetType: 'category',
      targetId: newName, targetLabel: newName, shopId: shopId,
      details: {'old_name': oldName, if (used > 0) 'used_by': used},
    );
  }

  static Future<void> saveBrand(String shopId, String name) async {
    _assertNotFrozen();
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
    _assertNotFrozen();
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
    _assertNotFrozen();
    if (old == neo) return;
    // Cascade vers les produits AVANT de retirer l'ancienne marque (sinon
    // deleteBrand jette : « utilisée par des produits »). Répercute le
    // renommage partout où la marque est référencée.
    int used = 0;
    for (final p in LocalStorageService.getProductsForShop(shopId)) {
      if (p.brand == old) {
        final u = p.copyWith(brand: neo);
        await HiveBoxes.productsBox.put(p.id!, _productToMap(u));
        _bgWrite({'table': 'products', 'op': 'upsert', 'data': _productToSupabase(u)});
        used++;
      }
    }
    await saveBrand(shopId, neo);
    // Retirer l'ancienne marque (déjà cascadée → plus référencée).
    final list = LocalStorageService.getBrands(shopId)..remove(old);
    await HiveBoxes.settingsBox.put('brands_$shopId', list);
    _bgWrite({'table': 'brands', 'op': 'delete', 'col': 'name', 'val': old,
              'data': {'shop_id': shopId, 'name': old}});
    if (used > 0) {
      LocalStorageService.invalidateProductsCache();
      _notify('products', shopId);
    }
    await ActivityLogService.log(
      action: 'brand_updated', targetType: 'brand',
      targetId: neo, targetLabel: neo, shopId: shopId,
      details: {'old_name': old, if (used > 0) 'used_by': used},
    );
  }

  static Future<void> saveUnit(String shopId, String name) async {
    _assertNotFrozen();
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
    _assertNotFrozen();
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

  // ══ POSTES DE L'ÉTABLISSEMENT (hotfix_160) ════════════════════════
  //
  // Serveur, Cuisinier, Livreur… La liste appartient à la boutique : chaque
  // établissement a ses propres postes, et doit pouvoir en ajouter, en
  // renommer et en supprimer. Même mécanique que les marques et les unités —
  // (shop_id, name), écriture Hive immédiate puis push en arrière-plan.

  static const String _jobTitlesTable = 'job_titles';

  static String _jobTitlesKey(String shopId) => 'job_titles_$shopId';

  static Future<void> _putJobTitles(String shopId, List<String> list) =>
      HiveBoxes.settingsBox.put(_jobTitlesKey(shopId), list);

  static String _jobPermsKey(String shopId) => 'job_title_perms_$shopId';

  static Future<void> _putJobPerms(
          String shopId, Map<String, String> perms) =>
      HiveBoxes.settingsBox.put(_jobPermsKey(shopId), perms);

  /// Taux horaire des heures supplémentaires, par poste (hotfix_165).
  static String _jobRatesKey(String shopId) => 'job_title_rates_$shopId';

  static Future<void> _putJobRates(String shopId, Map<String, int> rates) =>
      HiveBoxes.settingsBox.put(_jobRatesKey(shopId), rates);

  /// Ajoute un poste, avec ou sans profil de droits.
  ///
  /// Sans effet sur le libellé s'il existe déjà (comparaison insensible à la
  /// casse : « serveur » et « Serveur » sont le même poste). [permissions] —
  /// clés `EmployeePermission.key` ; `null` laisse le profil INCHANGÉ, une
  /// liste vide efface les droits du poste.
  static Future<void> saveJobTitle(String shopId, String name,
      {List<String>? permissions, int? overtimeRate}) async {
    _assertNotFrozen();
    final clean = name.trim();
    if (clean.isEmpty) return;
    final list = LocalStorageService.getJobTitles(shopId);
    final isNew =
        !list.any((t) => t.toLowerCase() == clean.toLowerCase());
    if (isNew) {
      list.add(clean);
      await _putJobTitles(shopId, list);
    }
    if (permissions != null) {
      final perms = LocalStorageService.getJobTitlePerms(shopId)
        ..[clean] = permissions.join(',');
      await _putJobPerms(shopId, perms);
    }
    if (overtimeRate != null) {
      final rates = LocalStorageService.getJobTitleRates(shopId)
        ..[clean] = overtimeRate;
      await _putJobRates(shopId, rates);
    }
    _bgWrite({'table': _jobTitlesTable, 'op': 'upsert',
      'data': {
        'shop_id': shopId,
        'name': clean,
        // Colonne ajoutée par hotfix_161 : omise tant qu'aucun profil n'est
        // défini, pour qu'un poste simple continue de se synchroniser même
        // si le SQL n'a pas encore été appliqué.
        if (permissions != null) 'permissions': permissions.join(','),
        // Idem pour le taux horaire des heures supplémentaires (hotfix_165).
        if (overtimeRate != null) 'overtime_rate': overtimeRate,
      },
      'onConflict': 'shop_id,name'});
    if (isNew) {
      await ActivityLogService.log(
        action: 'job_title_created', targetType: 'job_title',
        targetId: clean, targetLabel: clean, shopId: shopId,
      );
    }
  }

  /// Retire un poste de la liste proposée.
  ///
  /// Ne débaptise personne : la fonction d'un employé vit sur son compte
  /// (`shop_memberships.job_title`). C'est l'écran appelant qui refuse la
  /// suppression tant que quelqu'un porte le poste — le faire ici obligerait
  /// cette couche à connaître les comptes.
  static Future<void> deleteJobTitle(String shopId, String name) async {
    _assertNotFrozen();
    final list = LocalStorageService.getJobTitles(shopId)
      ..removeWhere((t) => t.toLowerCase() == name.toLowerCase());
    await _putJobTitles(shopId, list);
    final perms = LocalStorageService.getJobTitlePerms(shopId)
      ..removeWhere((k, _) => k.toLowerCase() == name.toLowerCase());
    await _putJobPerms(shopId, perms);
    final rates = LocalStorageService.getJobTitleRates(shopId)
      ..removeWhere((k, _) => k.toLowerCase() == name.toLowerCase());
    await _putJobRates(shopId, rates);
    // Suppression filtrée sur (shop_id, name) : sans le shop_id, l'ordre
    // effacerait le poste dans TOUTES les boutiques de l'utilisateur.
    _bgWrite({'table': _jobTitlesTable, 'op': 'delete',
      'match': {'shop_id': shopId, 'name': name},
      'data': {'shop_id': shopId, 'name': name}});
    await ActivityLogService.log(
      action: 'job_title_deleted', targetType: 'job_title',
      targetId: name, targetLabel: name, shopId: shopId,
    );
  }

  /// Renomme un poste, EN CONSERVANT son profil de droits. La propagation
  /// vers les comptes qui le portent est du ressort de l'appelant (il a le
  /// notifier employés sous la main) — ici on ne touche qu'à la liste.
  static Future<void> renameJobTitle(
      String shopId, String old, String neo) async {
    final clean = neo.trim();
    if (clean.isEmpty || old == clean) return;
    final carried = LocalStorageService.getJobTitlePerms(shopId)[old];
    final carriedRate = LocalStorageService.getJobTitleRates(shopId)[old];
    await saveJobTitle(shopId, clean,
        permissions: carried == null
            ? null
            : carried.split(',').where((k) => k.isNotEmpty).toList(),
        overtimeRate: carriedRate);
    await deleteJobTitle(shopId, old);
    await ActivityLogService.log(
      action: 'job_title_updated', targetType: 'job_title',
      targetId: clean, targetLabel: clean, shopId: shopId,
      details: {'old_name': old},
    );
  }

  /// Amorce la liste des postes d'une boutique qui n'en a encore aucun.
  ///
  /// Trois sources fusionnées, dans cet ordre : le socle métier livré avec
  /// l'app, les ajouts manuels rangés sur CET appareil avant hotfix_160, et
  /// les libellés déjà portés par des comptes. Sans cet amorçage, une liste
  /// vide s'afficherait vide — et un poste du socle ne serait pas supprimable,
  /// puisqu'il ne serait écrit nulle part.
  ///
  /// N'a lieu QU'UNE FOIS par appareil et par boutique (drapeau
  /// `job_titles_seeded_<shopId>`). Sans ce drapeau, l'amorçage ne pourrait se
  /// déclencher que sur une liste vide — et les postes ajoutés à la main avant
  /// hotfix_160, qui occupent déjà cette clé, l'empêcheraient à jamais.
  ///
  /// Limite assumée : un appareil qui découvre la boutique APRÈS que le socle
  /// y a été élagué réintroduira les postes supprimés. Le drapeau est local,
  /// et une liste de métiers ne mérite pas la table de tombstones qu'il
  /// faudrait pour faire mieux.
  static Future<void> ensureJobTitlesSeeded(
      String shopId, List<String> seed) async {
    try {
      final flag = 'job_titles_seeded_$shopId';
      if (HiveBoxes.settingsBox.get(flag) == true) return;
      final out = <String>[];
      for (final raw in [
        ...LocalStorageService.getJobTitles(shopId), // ajouts déjà présents
        ...seed,
      ]) {
        final t = raw.trim();
        if (t.isEmpty) continue;
        if (out.any((e) => e.toLowerCase() == t.toLowerCase())) continue;
        out.add(t);
      }
      await HiveBoxes.settingsBox.put(flag, true);
      if (out.isEmpty) return;
      await _putJobTitles(shopId, out);
      for (final t in out) {
        _bgWrite({'table': _jobTitlesTable, 'op': 'upsert',
          'data': {'shop_id': shopId, 'name': t},
          'onConflict': 'shop_id,name'});
      }
      debugPrint('[DB] postes amorcés (${out.length}) pour $shopId');
    } catch (e) {
      debugPrint('[DB] ensureJobTitlesSeeded: $e');
    }
  }

  // ══ RÉGLAGES DU PERSONNEL (hotfix_165) ═══════════════════════════════
  //
  // L'heure de fermeture de l'établissement — la référence qui décide si un
  // départ est anticipé ou s'il vaut des heures supplémentaires.
  //
  // SYNCHRONISÉE, et non rangée dans les préférences de l'appareil : la leçon
  // du fond de caisse (hotfix_147). La tablette de la salle réglée sur 22 h et
  // le téléphone du gérant sur 23 h jugeraient différemment le même pointage,
  // et l'employé se verrait reprocher un départ anticipé selon l'écran ouvert.

  static String _staffClosingKey(String shopId) =>
      'staff_closing_time_$shopId';

  /// Règle l'heure de fermeture de la boutique. `null` ou vide la retire —
  /// plus rien n'est alors jugé, ce qui est le comportement d'avant la règle.
  static Future<void> setShopClosingTime(String shopId, String? hhmm) async {
    _assertNotFrozen();
    final clean = (hhmm ?? '').trim();
    await HiveBoxes.settingsBox.put(_staffClosingKey(shopId), clean);
    _bgWrite({'table': 'staff_settings', 'op': 'upsert',
      'data': {
        'shop_id': shopId,
        'closing_time': clean.isEmpty ? null : clean,
      },
      'onConflict': 'shop_id'});
    _notify('staff_settings', shopId);
  }

  static Future<void> syncStaffSettings(String shopId) async {
    try {
      final rows = await _db
          .from('staff_settings')
          .select('closing_time')
          .eq('shop_id', shopId)
          .limit(1) as List;
      // Boutique sans ligne : aucun horaire réglé. On écrit tout de même la
      // valeur vide, sinon un horaire supprimé sur un autre appareil
      // resterait éternellement en place sur celui-ci.
      final t = rows.isEmpty
          ? ''
          : (rows.first['closing_time']?.toString() ?? '');
      await HiveBoxes.settingsBox.put(_staffClosingKey(shopId), t);
      _notify('staff_settings', shopId);
    } catch (e) {
      debugPrint('[DB] syncStaffSettings: $e');
    }
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
      // POSTES — table ajoutée par hotfix_160. Sa lecture est isolée : tant
      // que le SQL n'est pas appliqué, elle échoue (42P01) et ne doit pas
      // emporter avec elle les catégories, marques et unités déjà écrites.
      try {
        // `permissions` (hotfix_161) demandée à part : si la colonne manque
        // encore, la requête entière échouerait et la boutique n'aurait plus
        // aucun poste. On retombe alors sur les seuls libellés.
        List rows;
        try {
          rows = await _db.from(_jobTitlesTable)
              .select('name,permissions,overtime_rate')
              .eq('shop_id', shopId) as List;
        } catch (_) {
          try {
            rows = await _db.from(_jobTitlesTable)
                .select('name,permissions').eq('shop_id', shopId) as List;
          } catch (_) {
            rows = await _db.from(_jobTitlesTable)
                .select('name').eq('shop_id', shopId) as List;
          }
        }
        await _putJobTitles(
            shopId, rows.map((r) => r['name'] as String).toList());
        final perms = <String, String>{};
        final rates = <String, int>{};
        for (final r in rows) {
          final p = (r as Map)['permissions']?.toString() ?? '';
          if (p.isNotEmpty) perms[r['name'] as String] = p;
          final rate = (r['overtime_rate'] as num?)?.toInt() ?? 0;
          if (rate > 0) rates[r['name'] as String] = rate;
        }
        await _putJobPerms(shopId, perms);
        await _putJobRates(shopId, rates);
      } catch (e) {
        debugPrint('[DB] syncMetadata postes: $e');
      }
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
      _executeOp({'table': 'job_titles',     'op': 'delete', 'col': 'shop_id',  'val': shopId, 'data': {}});
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
      // Les postes de l'établissement sont de la configuration, au même titre
      // que les unités : une remise à zéro qui garde le catalogue n'a aucune
      // raison de faire oublier qu'on emploie un chawarmier.
      'job_titles_$shopId',
      'job_title_perms_$shopId',
      // Le taux des heures supplémentaires et l'heure de fermeture sont de la
      // même nature : des règles de l'établissement, pas des données d'activité.
      'job_title_rates_$shopId',
      'staff_closing_time_$shopId',
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
    _assertNotFrozen();
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
    _assertNotFrozen();
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
    _assertNotFrozen();
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
    // `logo_url` est nullable côté DB (colonne ajoutée par hotfix_087).
    // Sans cette ligne, le sync écrasait le logo en local par null à
    // chaque pull → l'utilisateur perdait son logo au reload.
    logoUrl: r['logo_url'] as String?,
    currency: r['currency'] as String? ?? 'XAF',
    country: r['country'] as String? ?? 'CM',
    sector: r['sector'] as String? ?? 'retail',
    isActive: r['is_active'] as bool? ?? true,
    ownerId: r['owner_id']?.toString(),
    phone: r['phone'] as String?,
    whatsappPhone: r['whatsapp_phone'] as String?,
    email: r['email'] as String?,
    facebookPixelId: r['facebook_pixel_id'] as String?,
    // Colonne ajoutée par hotfix_178 : absente sur une base pas encore
    // migrée → on retombe sur le défaut plutôt que de casser le mapping.
    partnerDebtAlertDays:
        (r['partner_debt_alert_days'] as num?)?.toInt() ?? 30,
    createdAt: r['created_at'] != null
        ? DateTime.tryParse(r['created_at'] as String) : null,
    kind:         ShopKindX.fromKey(r['kind'] as String?),
    parentShopId: r['parent_shop_id'] as String?,
    status:          r['status'] as String? ?? 'active',
    suspendedAt:     r['suspended_at'] != null
        ? DateTime.tryParse(r['suspended_at'] as String) : null,
    suspendedReason: r['suspended_reason'] as String?,
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
    'track_stock': p.trackStock,
    'activity_id': p.activityId,
    'image_url': p.imageUrl, 'rating': p.rating,
    'draft_expires_at': p.draftExpiresAt?.toIso8601String(),
    'unit': p.unit, 'internal_notes': p.internalNotes,
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
    final deletedRaw = r['deleted_at'];
    final snapshot   = r['archived_snapshot'];
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
      // Colonne absente sur une base pas encore migrée (hotfix_168) → null.
      draftExpiresAt: r['draft_expires_at'] is String
          ? DateTime.tryParse(r['draft_expires_at'] as String) : null,
      isActive: r['is_active'] as bool? ?? true,
      isVisibleWeb: r['is_visible_web'] as bool? ?? false,
      // Défaut true : colonne absente sur une base pas encore migrée
      // (hotfix_138) → suivi de stock historique conservé.
      trackStock:   r['track_stock'] as bool? ?? true,
      // Secteur restaurant (hotfix_141). Colonne absente sur une base pas
      // encore migrée → null, le plat reste simplement non rattaché.
      activityId:   r['activity_id'] as String?,
      imageUrl: r['image_url'], rating: r['rating'] as int? ?? 0,
      // Colonnes absentes sur une base pas encore migrée (hotfix_169).
      unit:          r['unit'] as String?,
      internalNotes: r['internal_notes'] as String?,
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
      // hotfix_085 — soft-delete fields propagés par realtime.
      deletedAt: deletedRaw is String
          ? DateTime.tryParse(deletedRaw)
          : (deletedRaw is DateTime ? deletedRaw : null),
      deletedBy:    r['deleted_by']    as String?,
      deleteReason: r['delete_reason'] as String?,
      archivedSnapshot: snapshot is Map
          ? Map<String, dynamic>.from(snapshot)
          : null,
    );
  }

  // ══════════════════════════════════════════════════════════════════
  // CLIENTS
  // ══════════════════════════════════════════════════════════════════

  /// Sauvegarder un client : Hive immédiat + Supabase background.
  /// Valide l'unicité email/téléphone par boutique (sauf si skipValidation).
  static Future<void> saveClient(Client c, {bool skipValidation = false}) async {
    _assertNotFrozen();
    // 0. Validation unicité (email + phone par boutique)
    if (!skipValidation) {
      _validateClientLocalUniqueness(c);
      if (_i._isOnline) await _validateClientRemoteUniqueness(c);
    }
    // Capture l'ancien snapshot AVANT l'écriture, pour détecter un
    // changement de nom/téléphone à répercuter sur les commandes.
    final prevRaw = HiveBoxes.clientsBox.get(c.id);
    String? prevName, prevPhone;
    if (prevRaw != null) {
      final pm = Map<String, dynamic>.from(prevRaw);
      prevName  = pm['name']  as String?;
      prevPhone = pm['phone'] as String?;
    }
    // 1. Hive IMMÉDIATEMENT — offline-first
    HiveBoxes.clientsBox.put(c.id, _clientToMap(c));
    // 2. Supabase en arrière-plan — jamais bloquant
    _bgWrite({'table': 'clients', 'op': 'upsert', 'data': _clientToSupabase(c)});
    _notify('clients', c.storeId);
    // 3. Cascade : si le nom ou le téléphone a changé sur un client
    //    existant, propager sur le snapshot figé de toutes ses commandes.
    if (prevRaw != null && (prevName != c.name || prevPhone != c.phone)) {
      _cascadeClientCoordsToOrders(c);
    }
  }

  /// Propage un changement de nom/téléphone client sur le snapshot figé
  /// (`client_name` / `client_phone`) de TOUTES les commandes du client.
  ///
  /// Les commandes copient ces deux champs au moment de la vente (cf.
  /// [Sale.clientName] / [Sale.clientPhone]) ; sans cette cascade, corriger
  /// une faute de frappe ou un numéro changé ne se voyait pas dans
  /// l'historique, les factures regénérées, les exports ni les messages de
  /// livraison. On NE touche PAS aux champs de livraison (delivery_city /
  /// delivery_address) : ils sont propres à chaque commande, pas au profil.
  ///
  /// - Hive : mise à jour immédiate (UI + offline) des commandes en cache.
  /// - Supabase : un seul UPDATE filtré par client_id couvre TOUTES les
  ///   commandes (même celles hors cache local) ; le realtime aligne ensuite
  ///   les autres appareils. Passe par [_bgWrite] → rejoué au retour réseau.
  static void _cascadeClientCoordsToOrders(Client c) {
    var touched = false;
    for (final key in HiveBoxes.ordersBox.keys) {
      final raw = HiveBoxes.ordersBox.get(key);
      if (raw == null) continue;
      final m = Map<String, dynamic>.from(raw);
      if (m['client_id'] != c.id) continue;
      if (m['client_name'] == c.name && m['client_phone'] == c.phone) continue;
      m['client_name']  = c.name;
      m['client_phone'] = c.phone;
      HiveBoxes.ordersBox.put(key, m);
      touched = true;
    }
    _bgWrite({
      'table': 'orders',
      'op':    'update',
      'data':  {'client_name': c.name, 'client_phone': c.phone},
      'match': {'client_id': c.id, 'shop_id': c.storeId},
    });
    if (touched) _notify('orders', c.storeId);
  }

  /// Propage l'IDENTITÉ d'un produit (nom + image) vers les snapshots des
  /// lignes (`items`) de TOUTES les commandes qui le référencent — y compris
  /// l'historique — pour que le produit s'affiche partout avec ses valeurs à
  /// jour. Le PRIX des lignes reste FIGÉ (intégrité comptable). Hive immédiat
  /// + push Supabase par commande touchée + notify.
  static void _cascadeProductToOrders(
      Product p, String? prevName, String? prevImage) {
    final shopId = p.storeId;
    final pid = p.id;
    if (shopId == null || pid == null) return;
    // Rien à propager si l'identité n'a pas changé (ex. création, ou édition
    // de prix/stock seuls).
    if (p.name == prevName && p.imageUrl == prevImage) return;
    var touched = false;
    for (final key in HiveBoxes.ordersBox.keys) {
      final raw = HiveBoxes.ordersBox.get(key);
      if (raw == null) continue;
      final m = Map<String, dynamic>.from(raw);
      if (m['shop_id'] != shopId) continue;
      if (EntityCascade.applyProductIdentityToOrder(m,
          productId: pid, newName: p.name, newImageUrl: p.imageUrl)) {
        HiveBoxes.ordersBox.put(key, m);
        touched = true;
        // jsonb `items` mis à jour pour cette commande précise.
        _bgWrite({
          'table': 'orders',
          'op':    'update',
          'data':  {'items': m['items']},
          'match': {'id': m['id']},
        });
      }
    }
    if (touched) _notify('orders', shopId);
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

  /// Sync une commande vers Supabase en arrière-plan.
  /// Marque l'id dans `_recentLocalOrderWrites` pour bloquer les events
  /// realtime qui pourraient ramener un snapshot stale (cf.
  /// `_recentLocalOrderWrites` doc).
  static void bgWriteOrder(Map<String, dynamic> orderMap) {
    final id = orderMap['id'] as String?;
    if (id != null && id.isNotEmpty) {
      _i._recentLocalOrderWrites[id] = DateTime.now().millisecondsSinceEpoch;
    }
    _bgWrite({'table': 'orders', 'op': 'upsert', 'data': orderMap});
  }

  /// Update CIBLÉ d'une commande : ne met à jour QUE les colonnes de [fields]
  /// (sémantique SQL `UPDATE ... SET`), sans toucher aux autres (ni `status`).
  ///
  /// À utiliser pour les mutations PARTIELLES (paiement, livraison, frais…) au
  /// lieu de [bgWriteOrder] (qui pousse la map complète). Raison : lors d'un
  /// changement de statut (ex. scheduled → processing), plusieurs push
  /// fire-and-forget de la map complète se faisaient la course ; un push
  /// portant l'ANCIEN statut, s'il atterrissait après le push du nouveau
  /// statut, faisait RÉGRESSER le statut (le trigger autorise
  /// processing → scheduled). En n'envoyant que les champs réellement
  /// modifiés, ces écritures ne touchent plus jamais `status` → plus de course.
  static void bgUpdateOrder(String orderId, Map<String, dynamic> fields) {
    if (orderId.isEmpty || fields.isEmpty) return;
    _i._recentLocalOrderWrites[orderId] =
        DateTime.now().millisecondsSinceEpoch;
    _bgWrite({'table': 'orders', 'op': 'update',
              'match': {'id': orderId}, 'data': fields});
  }

  /// Soft-delete d'une commande via la RPC `delete_sale` (hotfix_084).
  ///
  /// Comportement :
  ///   • Online → call direct. Lève si la RPC retourne une erreur métier
  ///     (suppression_statut_invalide, suppression_commande_payee,
  ///     motif_required) — l'appelant (`DeleteSaleUseCase`) doit catcher
  ///     pour rollback le marquage Hive local le cas échéant. Les erreurs
  ///     transitoires (réseau, 5xx) sont silencieusement enqueued.
  ///   • Offline → enqueue. L'op sera rejouée par `_flushQueue` au
  ///     retour réseau. Si le serveur refuse alors (statut/paiement),
  ///     l'erreur P0001 marquera l'op permanente et la droppera après
  ///     log — incohérence visible dans la bannière « Synchro incomplète ».
  ///
  /// La signature retourne `Future<void>` mais ne fait pas d'`await` sur
  /// l'enqueue : la caller a déjà marqué Hive avant d'appeler cette
  /// méthode (cf. `SaleLocalDatasource.softDeleteOrder`), donc l'UI est
  /// déjà cohérente côté offline.
  static Future<void> bgSoftDeleteSale({
    required String orderId,
    required String userId,
    required String reason,
  }) async {
    final params = <String, dynamic>{
      'p_sale_id': orderId,
      'p_user_id': userId,
      'p_reason':  reason,
    };
    if (_i._isOnline) {
      try {
        await _db.rpc('delete_sale', params: params);
      } catch (e) {
        final err = e.toString();
        // Erreurs métier explicites → propager au caller (UI dialog).
        // Ne PAS enqueue : réessayer ne marchera pas et masquerait le
        // problème (Hive marqué supprimé alors que SQL refuse).
        if (err.contains('P0001') || err.contains('P0002')) {
          rethrow;
        }
        // Erreur transitoire (réseau / 5xx) → enqueue pour réessai.
        _enqueue({'table': 'rpc', 'op': 'rpc', 'name': 'delete_sale',
                  'data': params});
      }
    } else {
      _enqueue({'table': 'rpc', 'op': 'rpc', 'name': 'delete_sale',
                'data': params});
    }
  }

  /// Restauration d'une commande soft-deleted via la RPC `restore_sale`
  /// (hotfix_084). Réservée super-admin (vérification côté SQL).
  /// Online uniquement — pas d'enqueue offline (l'écran de restauration
  /// est super-admin → suppose une session active).
  static Future<void> bgRestoreSale({
    required String orderId,
    required String userId,
  }) async {
    await _db.rpc('restore_sale', params: <String, dynamic>{
      'p_sale_id': orderId,
      'p_user_id': userId,
    });
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
    _assertNotFrozen();
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

      // Montant dépensé par le client = Σ lignes (custom ?? unit) × qty
      // × (1 - disc/100) - discount_amount + TVA. Les FRAIS DE LIVRAISON
      // sont EXCLUS : ils sont reversés au livreur/partenaire, ce n'est
      // pas un revenu boutique ni une dépense du client pour les produits.
      // Aligné sur le calcul des ventes du dashboard
      // (_computeFinancialSnapshot : orderTotal sans fees).
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
      final discountAmt = (o['discount_amount'] as num?)?.toDouble() ?? 0;
      final taxRate     = (o['tax_rate'] as num?)?.toDouble() ?? 0;
      final taxable     = subtotal - discountAmt;
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
      // TODO P1-B-suite : syncClients présente le même angle mort que
      // syncOrders/syncExpenses avant leur correctif — cette purge ne
      // consulte pas la file d'attente, donc un client créé hors ligne et
      // pas encore poussé peut être effacé. Non traité dans ce commit
      // (périmètre financier), le correctif tient en un appel à
      // `_pendingIdsFor('clients')`.
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
  // Schema versioning — cf. lib/core/storage/schema_migrator.dart.
  static final _clientMigrator = SchemaMigrator(
    currentVersion: 1, steps: const {});

  // Hive persiste city/district séparément + address legacy pour compat.
  static Map<String, dynamic> _clientToMap(Client c) => {
    'schema_version': _clientMigrator.currentVersion,
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

  static Client _clientFromMap(Map<String, dynamic> rawM) {
    final m = _clientMigrator.migrate(rawM);
    return Client(
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
  }

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