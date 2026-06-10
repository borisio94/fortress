import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/shop_selector/domain/entities/shop_summary.dart';
import '../../features/auth/domain/entities/user.dart';
import '../../core/storage/local_storage_service.dart';
import '../../core/storage/hive_boxes.dart';
import '../../core/config/supabase_client.dart';
import '../../core/database/app_database.dart';

// ─── Boutique active ──────────────────────────────────────────────────────────

final currentShopProvider =
NotifierProvider<CurrentShopNotifier, ShopSummary?>(
  CurrentShopNotifier.new,
);

class CurrentShopNotifier extends Notifier<ShopSummary?> {
  @override
  ShopSummary? build() {
    // Survivre aux navigations — jamais recréé tant que ProviderScope vit
    ref.keepAlive();

    // Réactif : quand AppDatabase resynchronise les boutiques (ex. logo_url
    // récupéré après login via getMyShops), relire la boutique active pour
    // rafraîchir l'UI (sinon le logo n'apparaît qu'après une actualisation).
    void onShopsChanged(String table, String _) {
      if (table != 'shops') return;
      final cur = state;
      if (cur == null) return;
      final fresh = LocalStorageService.getShop(cur.id);
      if (fresh != null && fresh.logoUrl != cur.logoUrl) state = fresh;
    }
    AppDatabase.addListener(onShopsChanged);
    ref.onDispose(() => AppDatabase.removeListener(onShopsChanged));

    // Tout le chemin de lecture est wrapped : si Hive renvoie une map
    // corrompue / un cast échoue, on retourne null plutôt que de propager
    // une exception qui mettrait le provider en état d'erreur permanent
    // (et bloquerait la page paramètres sur un spinner).
    try {
      final userId = SupabaseClientService.currentUserId
          ?? LocalStorageService.getCurrentUser()?.id;
      if (userId == null) return null;

      // 1. Essayer l'activeShopId sauvegardé
      final lastId = LocalStorageService.getActiveShopId(userId);
      if (lastId != null) {
        final shop = LocalStorageService.getShop(lastId);
        if (shop != null) return shop;
      }

      // 2. Fallback : première boutique dans Hive
      final shops = LocalStorageService.getShopsForUser(userId);
      if (shops.isNotEmpty) return shops.first;
    } catch (e) {
      debugPrint('[CurrentShopProvider] build error: $e');
    }
    return null;
  }

  void setShop(ShopSummary shop) {
    state = shop;
    final userId = SupabaseClientService.currentUserId
        ?? LocalStorageService.getCurrentUser()?.id;
    if (userId != null) {
      LocalStorageService.saveActiveShopId(userId, shop.id);
    }
  }

  void clearShop() {
    state = null;
    final userId = SupabaseClientService.currentUserId
        ?? LocalStorageService.getCurrentUser()?.id;
    if (userId != null) {
      LocalStorageService.saveActiveShopId(userId, null);
    }
  }
}

// ─── Liste des boutiques ──────────────────────────────────────────────────────

final myShopsProvider =
NotifierProvider<MyShopsNotifier, List<ShopSummary>>(
  MyShopsNotifier.new,
);

class MyShopsNotifier extends Notifier<List<ShopSummary>> {
  @override
  List<ShopSummary> build() {
    ref.keepAlive();
    return _fromHive();
  }

  List<ShopSummary> _fromHive() {
    final userId = SupabaseClientService.currentUserId
        ?? LocalStorageService.getCurrentUser()?.id;
    if (userId == null) return [];
    return LocalStorageService.getShopsForUser(userId);
  }

  void refresh() {
    final fresh = _fromHive();
    if (fresh.isNotEmpty) state = fresh;
  }

  /// Reçoit les boutiques depuis Supabase.
  /// Sauvegarde boutiques ET memberships dans Hive de manière synchrone
  /// via `LocalStorageService.saveShop` (sérialisation complète, incluant
  /// whatsapp_phone, kind, parent_shop_id, logo_url — l'ancienne version
  /// dupliquée localement perdait ces champs au refresh).
  void setFromSupabase(List<ShopSummary> shops, {String? userId}) {
    if (shops.isEmpty) return;
    state = shops;

    final uid = userId
        ?? SupabaseClientService.currentUserId
        ?? LocalStorageService.getCurrentUser()?.id;
    if (uid == null) return;

    for (final shop in shops) {
      LocalStorageService.saveShop(shop);
      HiveBoxes.membershipsBox.put('${uid}_${shop.id}', {
        'user_id': uid, 'shop_id': shop.id, 'shop_name': shop.name,
        'role': UserRole.admin.name,
        'joined_at': DateTime.now().toIso8601String(),
      });
    }
    // Persister l'activeShopId du premier shop si aucun défini
    final activeId = LocalStorageService.getActiveShopId(uid);
    if (activeId == null && shops.isNotEmpty) {
      LocalStorageService.saveActiveShopId(uid, shops.first.id);
    }
  }

  void addShop(ShopSummary shop) {
    if (!state.any((s) => s.id == shop.id)) {
      state = [...state, shop];
      LocalStorageService.saveShop(shop);
    }
  }

  /// Remplace la boutique correspondante (par id) après modification.
  void updateShop(ShopSummary shop) {
    final idx = state.indexWhere((s) => s.id == shop.id);
    if (idx == -1) {
      addShop(shop);
      return;
    }
    final next = [...state];
    next[idx] = shop;
    state = next;
    LocalStorageService.saveShop(shop);
  }

  void clear() => state = [];
}

/// Raccourci : ID de la boutique active
final currentShopIdProvider = Provider<String?>(
      (ref) => ref.watch(currentShopProvider)?.id,
);