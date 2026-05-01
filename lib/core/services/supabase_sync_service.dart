import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/supabase_service.dart';
import '../storage/local_storage_service.dart';
import '../../features/shop_selector/domain/entities/shop_summary.dart';
import '../../features/auth/domain/entities/user.dart';
import '../../features/inventaire/domain/entities/product.dart';

// ─────────────────────────────────────────────────────────────────────────────
// SYNC SERVICE — synchronise Supabase ↔ Hive local
// Stratégie : write-through (écrit partout simultanément)
// ─────────────────────────────────────────────────────────────────────────────

class SupabaseSyncService {
  static final _db = SupabaseService.client;

  // ══════════════════════════════════════════════════════════════════
  // BOUTIQUES
  // ══════════════════════════════════════════════════════════════════

  static Future<void> saveShop(ShopSummary shop) async {
    // 1. Hive local (immédiat)
    await LocalStorageService.saveShop(shop);

    // 2. Supabase (si connecté)
    if (!SupabaseService.isAuthenticated) return;
    try {
      await _db.from('shops').upsert({
        'id':         shop.id,
        'owner_id':   shop.ownerId ?? SupabaseService.currentUserId,
        'name':       shop.name,
        'sector':     shop.sector,
        'currency':   shop.currency,
        'country':    shop.country,
        'phone':      shop.phone,
        'email':      shop.email,
        'is_active':  shop.isActive,
      });

      // Membership propriétaire
      if (shop.ownerId != null) {
        await _db.from('shop_memberships').upsert({
          'shop_id': shop.id,
          'user_id': shop.ownerId,
          'role':    'admin',
        }, onConflict: 'shop_id,user_id');
      }
    } catch (e) {
      // Silencieux — Hive a déjà la donnée
    }
  }

  static Future<List<ShopSummary>> getShopsForUser(String userId) async {
    // 1. Cache Hive d'abord
    final local = LocalStorageService.getShopsForUser(userId);

    // 2. Synchroniser depuis Supabase en arrière-plan
    if (SupabaseService.isAuthenticated) {
      _syncShopsFromSupabase(userId);
    }

    return local;
  }

  static Future<void> _syncShopsFromSupabase(String userId) async {
    try {
      final data = await _db
          .from('shops')
          .select('*, shop_memberships!inner(user_id, role)')
          .eq('shop_memberships.user_id', userId);

      for (final row in data as List) {
        final shop = ShopSummary(
          id:        row['id'],
          name:      row['name'],
          sector:    row['sector'] ?? 'retail',
          currency:  row['currency'] ?? 'XAF',
          country:   row['country'] ?? 'CM',
          phone:     row['phone'],
          email:     row['email'],
          ownerId:   row['owner_id'],
          isActive:  row['is_active'] ?? true,
          createdAt: row['created_at'] != null
              ? DateTime.parse(row['created_at']) : null,
        );
        await LocalStorageService.saveShop(shop);

        // Membership
        final memberships = row['shop_memberships'] as List?;
        if (memberships != null) {
          for (final m in memberships) {
            final role = _roleFromString(m['role'] as String? ?? 'cashier');
            await LocalStorageService.saveMembership(
              userId:   m['user_id'] as String,
              shopId:   shop.id!,
              shopName: shop.name,
              role:     role,
            );
          }
        }
      }
    } catch (_) {}
  }

  // ══════════════════════════════════════════════════════════════════
  // PRODUITS
  // ══════════════════════════════════════════════════════════════════

  static Future<void> saveProduct(Product product) async {
    // 1. Hive local
    await LocalStorageService.saveProduct(product);

    // 2. Supabase
    if (!SupabaseService.isAuthenticated) return;
    try {
      await _db.from('products').upsert({
        'id':             product.id,
        'store_id':       product.storeId,
        'category_id':    product.categoryId,
        'brand':          product.brand,
        'name':           product.name,
        'description':    product.description,
        'barcode':        product.barcode,
        'sku':            product.sku,
        'price_buy':      product.priceBuy,
        'price_sell_pos': product.priceSellPos,
        'price_sell_web': product.priceSellWeb,
        'tax_rate':       product.taxRate,
        'stock_qty':      product.stockQty,
        'stock_min_alert':product.stockMinAlert,
        'is_active':      product.isActive,
        'is_visible_web': product.isVisibleWeb,
        'image_url':      product.imageUrl,
        'rating':         product.rating,
        'variants':       product.variants.map((v) => {
          'id': v.id, 'name': v.name, 'sku': v.sku,
          'barcode': v.barcode, 'supplier': v.supplier, 'supplier_ref': v.supplierRef,
          'price_buy': v.priceBuy, 'price_sell_pos': v.priceSellPos,
          'price_sell_web': v.priceSellWeb, 'stock_qty': v.stockQty,
          'stock_min_alert': v.stockMinAlert,
          'image_url': v.imageUrl,
          'secondary_image_urls': v.secondaryImageUrls,
          'is_main': v.isMain,
          'promo_enabled': v.promoEnabled,
          'promo_price': v.promoPrice,
          'promo_start': v.promoStart?.toIso8601String(),
          'promo_end':   v.promoEnd?.toIso8601String(),
        }).toList(),
        'expenses': product.expenses,
      });
    } catch (_) {}
  }

  static Future<void> deleteProduct(String productId, String shopId) async {
    LocalStorageService.deleteProduct(productId);
    if (!SupabaseService.isAuthenticated) return;
    try {
      await _db.from('products').delete().eq('id', productId);
    } catch (_) {}
  }

  static Future<List<Product>> getProductsForShop(String shopId) async {
    final local = LocalStorageService.getProductsForShop(shopId);
    if (SupabaseService.isAuthenticated) {
      _syncProductsFromSupabase(shopId);
    }
    return local;
  }

  static Future<void> _syncProductsFromSupabase(String shopId) async {
    try {
      final data = await _db
          .from('products')
          .select()
          .eq('store_id', shopId);

      for (final row in data as List) {
        final variantsJson = (row['variants'] as List?) ?? [];
        final variants = variantsJson.map((v) => ProductVariant(
          id:            v['id'],
          name:          v['name'] ?? '',
          sku:           v['sku'],
          barcode:       v['barcode'],
          supplier:      v['supplier'],
          supplierRef:   v['supplier_ref'],
          priceBuy:      (v['price_buy'] as num?)?.toDouble() ?? 0,
          priceSellPos:  (v['price_sell_pos'] as num?)?.toDouble() ?? 0,
          priceSellWeb:  (v['price_sell_web'] as num?)?.toDouble() ?? 0,
          stockAvailable: v['stock_available'] as int? ?? (v['stock_qty'] as int? ?? 0),
          stockPhysical:  v['stock_physical'] as int? ?? (v['stock_qty'] as int? ?? 0),
          stockOrdered:   v['stock_ordered'] as int? ?? 0,
          stockBlocked:   v['stock_blocked'] as int? ?? 0,
          stockMinAlert: v['stock_min_alert'] as int? ?? 1,
          imageUrl:      v['image_url'],
          secondaryImageUrls: (v['secondary_image_urls'] as List?)
              ?.map((e) => e as String).toList() ?? [],
          isMain:        v['is_main'] as bool? ?? false,
          promoEnabled:  v['promo_enabled'] as bool? ?? false,
          promoPrice:    (v['promo_price'] as num?)?.toDouble(),
          promoStart:    v['promo_start'] != null
              ? DateTime.tryParse(v['promo_start'] as String) : null,
          promoEnd:      v['promo_end'] != null
              ? DateTime.tryParse(v['promo_end'] as String) : null,
        )).toList();

        final expensesJson = (row['expenses'] as List?) ?? [];
        final expenses = expensesJson
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();

        final product = Product(
          id:            row['id'],
          storeId:       row['store_id'],
          categoryId:    row['category_id'],
          brand:         row['brand'],
          name:          row['name'],
          description:   row['description'],
          barcode:       row['barcode'],
          sku:           row['sku'],
          priceBuy:      (row['price_buy'] as num?)?.toDouble() ?? 0,
          priceSellPos:  (row['price_sell_pos'] as num?)?.toDouble() ?? 0,
          priceSellWeb:  (row['price_sell_web'] as num?)?.toDouble() ?? 0,
          taxRate:       (row['tax_rate'] as num?)?.toDouble() ?? 0,
          stockQty:      row['stock_qty'] as int? ?? 0,
          stockMinAlert: row['stock_min_alert'] as int? ?? 5,
          isActive:      row['is_active'] as bool? ?? true,
          isVisibleWeb:  row['is_visible_web'] as bool? ?? false,
          imageUrl:      row['image_url'],
          rating:        row['rating'] as int? ?? 0,
          variants:      variants,
          expenses:      expenses,
        );
        await LocalStorageService.saveProduct(product);
      }
    } catch (_) {}
  }

  // ══════════════════════════════════════════════════════════════════
  // CATÉGORIES / MARQUES / UNITÉS
  // ══════════════════════════════════════════════════════════════════

  static Future<void> saveCategory(String shopId, String name) async {
    await LocalStorageService.saveCategory(shopId, name);
    if (!SupabaseService.isAuthenticated) return;
    try {
      await _db.from('categories').upsert(
          {'shop_id': shopId, 'name': name},
          onConflict: 'shop_id,name');
    } catch (_) {}
  }

  static Future<void> saveBrand(String shopId, String name) async {
    await LocalStorageService.saveBrand(shopId, name);
    if (!SupabaseService.isAuthenticated) return;
    try {
      await _db.from('brands').upsert(
          {'shop_id': shopId, 'name': name},
          onConflict: 'shop_id,name');
    } catch (_) {}
  }

  static Future<void> saveUnit(String shopId, String name) async {
    await LocalStorageService.saveUnit(shopId, name);
    if (!SupabaseService.isAuthenticated) return;
    try {
      await _db.from('units').upsert(
          {'shop_id': shopId, 'name': name},
          onConflict: 'shop_id,name');
    } catch (_) {}
  }

  static Future<void> syncCategoriesBrandsUnits(String shopId) async {
    if (!SupabaseService.isAuthenticated) return;
    try {
      // Catégories
      final cats = await _db.from('categories')
          .select('name').eq('shop_id', shopId);
      for (final r in cats as List) {
        await LocalStorageService.saveCategory(shopId, r['name']);
      }
      // Marques
      final brands = await _db.from('brands')
          .select('name').eq('shop_id', shopId);
      for (final r in brands as List) {
        await LocalStorageService.saveBrand(shopId, r['name']);
      }
      // Unités
      final units = await _db.from('units')
          .select('name').eq('shop_id', shopId);
      for (final r in units as List) {
        await LocalStorageService.saveUnit(shopId, r['name']);
      }
    } catch (_) {}
  }

  // ══════════════════════════════════════════════════════════════════
  // SYNC COMPLÈTE — appelée au démarrage de l'app
  // ══════════════════════════════════════════════════════════════════

  static Future<void> syncAll(String userId, String? shopId) async {
    if (!SupabaseService.isAuthenticated) return;
    await _syncShopsFromSupabase(userId);
    if (shopId != null) {
      await _syncProductsFromSupabase(shopId);
      await syncCategoriesBrandsUnits(shopId);
    }
  }

  // ── Helper ─────────────────────────────────────────────────────────────────
  static UserRole _roleFromString(String s) => switch (s) {
    'admin'   => UserRole.admin,
    'manager' => UserRole.manager,
    'cashier' => UserRole.cashier,
    _         => UserRole.viewer,
  };
}