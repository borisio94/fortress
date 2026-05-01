import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../features/shop_selector/domain/entities/shop_summary.dart';
import '../../features/auth/domain/entities/user.dart';
import '../../core/storage/local_storage_service.dart';
import '../../core/storage/hive_boxes.dart';
import '../../core/config/supabase_client.dart';

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
  /// Sauvegarde boutiques ET memberships dans Hive de manière synchrone.
  void setFromSupabase(List<ShopSummary> shops, {String? userId}) {
    if (shops.isEmpty) return;
    state = shops;

    final uid = userId
        ?? SupabaseClientService.currentUserId
        ?? LocalStorageService.getCurrentUser()?.id;
    if (uid == null) return;

    for (final shop in shops) {
      // saveShop : synchrone dans la cache Hive (persiste en async)
      HiveBoxes.shopsBox.put(shop.id, _shopToMap(shop));
      // saveMembership : synchrone dans la cache Hive
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

  Map<String, dynamic> _shopToMap(ShopSummary s) => {
    'id': s.id, 'name': s.name, 'logo_url': s.logoUrl,
    'currency': s.currency, 'country': s.country, 'sector': s.sector,
    'is_active': s.isActive, 'today_sales': s.todaySales,
    'owner_id': s.ownerId, 'phone': s.phone, 'email': s.email,
    'created_at': s.createdAt?.toIso8601String(),
  };

  void addShop(ShopSummary shop) {
    if (!state.any((s) => s.id == shop.id)) {
      state = [...state, shop];
      HiveBoxes.shopsBox.put(shop.id, _shopToMap(shop));
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
    HiveBoxes.shopsBox.put(shop.id, _shopToMap(shop));
  }

  void clear() => state = [];
}

/// Raccourci : ID de la boutique active
final currentShopIdProvider = Provider<String?>(
      (ref) => ref.watch(currentShopProvider)?.id,
);