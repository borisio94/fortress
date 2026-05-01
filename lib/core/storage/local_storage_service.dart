import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide User;
import 'hive_boxes.dart';
import '../config/supabase_client.dart';
import '../../features/auth/domain/entities/user.dart';
import '../../features/shop_selector/domain/entities/shop_summary.dart';
import '../../features/inventaire/domain/entities/product.dart';

class LocalStorageService {

  // ══════════════════════════════════════════════════════════════════
  // UTILISATEURS
  // ══════════════════════════════════════════════════════════════════

  static Future<void> saveUser(User user) async =>
      HiveBoxes.usersBox.put(user.id, _userToMap(user));

  /// Récupérer TOUS les utilisateurs — utilisé par le mock auth
  static List<User> getAllUsers() =>
      HiveBoxes.usersBox.values
          .map((m) => _userFromMap(Map<String, dynamic>.from(m)))
          .toList();

  static User? getUser(String userId) {
    final m = HiveBoxes.usersBox.get(userId);
    if (m == null) return null;
    final user = _userFromMap(Map<String, dynamic>.from(m));
    // Enrichir avec les memberships depuis membershipsBox
    final memberships = getMembershipsForUser(userId);
    if (memberships.isEmpty) return user;
    return user.copyWith(memberships: memberships);
  }

  static User? getCurrentUser() {
    final id = HiveBoxes.settingsBox.get('current_user_id') as String?;
    return id != null ? getUser(id) : null;
  }

  static Future<void> setCurrentUserId(String id) =>
      HiveBoxes.settingsBox.put('current_user_id', id);

  static Future<void> clearCurrentUser() =>
      HiveBoxes.settingsBox.delete('current_user_id');

  /// Dernier email utilisé au login (pré-remplissage de l'écran de connexion).
  /// NON effacé au logout pour éviter de retaper à chaque reconnexion.
  static Future<void> saveLastLoginEmail(String email) =>
      HiveBoxes.settingsBox.put('last_login_email', email.trim().toLowerCase());

  static String? getLastLoginEmail() =>
      HiveBoxes.settingsBox.get('last_login_email') as String?;

  // ══════════════════════════════════════════════════════════════════
  // BOUTIQUES
  // ══════════════════════════════════════════════════════════════════

  static Future<void> saveShop(ShopSummary shop) =>
      HiveBoxes.shopsBox.put(shop.id, _shopToMap(shop));

  static List<ShopSummary> getShopsForUser(String userId) {
    // Récupérer les IDs de boutiques via les memberships
    final memberShopIds = HiveBoxes.membershipsBox.values
        .map((m) => Map<String, dynamic>.from(m))
        .where((m) => m['user_id'] == userId)
        .map((m) => m['shop_id'] as String?)
        .whereType<String>()
        .toSet();

    // ⚠ Pas de fallback "retourner toutes les boutiques" : si on ne trouve
    // rien pour cet userId, on retourne une liste vide. Le fallback
    // historique laissait fuiter les boutiques d'autres comptes locaux
    // quand les memberships n'étaient pas encore syncés.
    return HiveBoxes.shopsBox.values
        .map((m) => _shopFromMap(Map<String, dynamic>.from(m)))
        .where((s) =>
            s.ownerId == userId ||         // propriétaire
            memberShopIds.contains(s.id))  // membre
        .toList();
  }

  static ShopSummary? getShop(String id) {
    final m = HiveBoxes.shopsBox.get(id);
    return m != null ? _shopFromMap(Map<String, dynamic>.from(m)) : null;
  }

  // ══════════════════════════════════════════════════════════════════
  // MARQUES — par boutique
  // ══════════════════════════════════════════════════════════════════

  static Future<void> saveBrand(String shopId, String brand) async {
    final key = 'brands_$shopId';
    final existing = getBrands(shopId);
    if (!existing.contains(brand)) {
      existing.add(brand);
      await HiveBoxes.settingsBox.put(key, existing);
    }

  }

  static List<String> getBrands(String shopId) {
    final raw = HiveBoxes.settingsBox.get('brands_$shopId');
    if (raw == null) return [];
    return List<String>.from(raw as List);
  }

  // ══════════════════════════════════════════════════════════════════
  // UNITÉS — par boutique
  // ══════════════════════════════════════════════════════════════════

  static Future<void> saveUnit(String shopId, String unit) async {
    final key = 'units_$shopId';
    final existing = getUnits(shopId);
    if (!existing.contains(unit)) {
      existing.add(unit);
      await HiveBoxes.settingsBox.put(key, existing);
    }

  }

  static List<String> getUnits(String shopId) {
    final raw = HiveBoxes.settingsBox.get('units_$shopId');
    if (raw == null) return [];
    return List<String>.from(raw as List);
  }

  // ══════════════════════════════════════════════════════════════════
  // PRODUITS — stockage persistent par shopId
  // ══════════════════════════════════════════════════════════════════

  static Future<void> saveProduct(Product p) async {
    // Hive local uniquement — AppDatabase gère la sync Supabase
    invalidateProductsCache();
    await HiveBoxes.productsBox.put(p.id, _productToMap(p));
  }

  static Future<void> deleteProduct(String productId) async {
    // Hive local uniquement — AppDatabase gère la sync Supabase
    invalidateProductsCache();
    await HiveBoxes.productsBox.delete(productId);
  }

  // ── Cache mémoire des produits ────────────────────────────────────
  // Évite de re-désérialiser toute la productsBox (100+ produits × variantes)
  // à chaque appel de getProductsForShop.
  //
  // Invalidation : appelée SYNCHRONIQUEMENT par tous les sites d'écriture
  // (saveProduct ici + AppDatabase.saveProduct/deleteProduct). Le watcher
  // `box.watch()` est conservé en filet de sécurité pour les writes
  // externes (Supabase realtime sync) — mais il est asynchrone (event
  // loop) et ne suffit pas dans une boucle serrée comme `decrementStock`
  // qui itère sur plusieurs variantes du même produit : sans invalidation
  // synchrone, la 2ᵉ itération lirait un cache pollué et écraserait la
  // 1ʳᵉ écriture.
  static final Map<String, List<Product>> _productsCache = {};
  static bool _productsWatcherInit = false;

  /// Vide le cache produits — à appeler synchroniquement après chaque
  /// écriture pour garantir que la lecture suivante désérialise depuis
  /// Hive (qui a la valeur à jour via l'`await put(...)`).
  static void invalidateProductsCache() => _productsCache.clear();

  static void _ensureProductsWatcher() {
    if (_productsWatcherInit) return;
    try {
      HiveBoxes.productsBox.watch().listen((_) => _productsCache.clear());
      _productsWatcherInit = true;
    } catch (_) {
      // La box n'est pas encore ouverte — on réessaie au prochain appel.
    }
  }

  static List<Product> getProductsForShop(String shopId) {
    _ensureProductsWatcher();
    final cached = _productsCache[shopId];
    if (cached != null) return cached;
    final list = HiveBoxes.productsBox.values
        .map((m) => _productFromMap(Map<String, dynamic>.from(m)))
        .where((p) => p.storeId == shopId)
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    _productsCache[shopId] = list;
    return list;
  }

  static Product? getProduct(String id) {
    final m = HiveBoxes.productsBox.get(id);
    return m != null ? _productFromMap(Map<String, dynamic>.from(m)) : null;
  }

  // ══════════════════════════════════════════════════════════════════
  // CATÉGORIES — par boutique
  // ══════════════════════════════════════════════════════════════════

  static Future<void> saveCategory(String shopId, String category) async {
    final key = 'categories_$shopId';
    final existing = getCategories(shopId);
    if (!existing.contains(category)) {
      existing.add(category);
      await HiveBoxes.settingsBox.put(key, existing);
    }

  }

  static List<String> getCategories(String shopId) {
    final key = 'categories_$shopId';
    final raw = HiveBoxes.settingsBox.get(key);
    if (raw == null) return [];
    return List<String>.from(raw as List);
  }

  // ══════════════════════════════════════════════════════════════════
  // IMAGES — copie dans le dossier documents de l'app
  // ══════════════════════════════════════════════════════════════════

  /// Copie un fichier image dans le répertoire persistant de l'app.
  /// Retourne le chemin permanent.
  static Future<String> saveImageFile(File source, {String? name}) async {
    final dir = await getApplicationDocumentsDirectory();
    final imgDir = Directory('${dir.path}/product_images');
    if (!imgDir.existsSync()) imgDir.createSync(recursive: true);
    final filename = name ?? '${DateTime.now().millisecondsSinceEpoch}.jpg';
    final dest = File('${imgDir.path}/$filename');
    await source.copy(dest.path);
    return dest.path;
  }

  // ══════════════════════════════════════════════════════════════════
  // MEMBERSHIPS
  // ══════════════════════════════════════════════════════════════════

  static Future<void> saveMembership({
    required String userId, required String shopId,
    required String shopName, required UserRole role,
  }) => HiveBoxes.membershipsBox.put('${userId}_$shopId', {
    'user_id': userId, 'shop_id': shopId, 'shop_name': shopName,
    'role': role.name, 'joined_at': DateTime.now().toIso8601String(),
  });

  static List<ShopMembership> getMembershipsForUser(String userId) =>
      HiveBoxes.membershipsBox.values
          .map((m) => Map<String, dynamic>.from(m))
          .where((m) => m['user_id'] == userId)
          .map((m) => ShopMembership(
        shopId:   m['shop_id'],
        shopName: m['shop_name'],
        role:     _roleFrom(m['role']),
        joinedAt: DateTime.parse(m['joined_at']),
      ))
          .toList();

  // ══════════════════════════════════════════════════════════════════
  // FILE OFFLINE
  // ══════════════════════════════════════════════════════════════════

  static Future<void> enqueueOperation({
    required String type, required String entityId,
    required Map<String, dynamic> payload,
  }) => HiveBoxes.offlineQueueBox.put(
      '${type}_${entityId}_${DateTime.now().millisecondsSinceEpoch}',
      {'type': type, 'entity_id': entityId, 'payload': payload,
        'created_at': DateTime.now().toIso8601String(), 'retries': 0});

  static List<Map<String, dynamic>> getPendingOperations() =>
      HiveBoxes.offlineQueueBox.values
          .map((m) => Map<String, dynamic>.from(m)).toList()
        ..sort((a, b) => (a['created_at'] as String)
            .compareTo(b['created_at'] as String));

  static Future<void> removeOperation(String key) =>
      HiveBoxes.offlineQueueBox.delete(key);

  // ══════════════════════════════════════════════════════════════════
  // SÉRIALISEURS
  // ══════════════════════════════════════════════════════════════════

  static Map<String, dynamic> _userToMap(User u) => {
    'id': u.id, 'email': u.email, 'name': u.name,
    'phone': u.phone, 'avatar_url': u.avatarUrl,
    'created_at': u.createdAt.toIso8601String(),
  };

  static User _userFromMap(Map<String, dynamic> m) => User(
    id: m['id'], email: m['email'], name: m['name'],
    phone: m['phone'], avatarUrl: m['avatar_url'],
    createdAt: DateTime.parse(m['created_at']),
  );

  static Map<String, dynamic> _shopToMap(ShopSummary s) => {
    'id': s.id, 'name': s.name, 'logo_url': s.logoUrl,
    'currency': s.currency, 'country': s.country, 'sector': s.sector,
    'is_active': s.isActive, 'today_sales': s.todaySales,
    'owner_id': s.ownerId, 'phone': s.phone, 'email': s.email,
    'created_at': s.createdAt?.toIso8601String(),
  };

  static ShopSummary _shopFromMap(Map<String, dynamic> m) => ShopSummary(
    id: m['id'], name: m['name'], logoUrl: m['logo_url'],
    currency: m['currency'], country: m['country'], sector: m['sector'],
    isActive: m['is_active'] ?? true, todaySales: m['today_sales'],
    ownerId: m['owner_id'], phone: m['phone'], email: m['email'],
    createdAt: m['created_at'] != null
        ? DateTime.parse(m['created_at']) : null,
  );

  static Map<String, dynamic> _productToMap(Product p) => {
    'id': p.id, 'store_id': p.storeId, 'category_id': p.categoryId,
    'brand': p.brand, 'name': p.name, 'description': p.description,
    'barcode': p.barcode, 'sku': p.sku,
    'price_buy': p.priceBuy, 'customs_fee': p.customsFee,
    'price_sell_pos': p.priceSellPos, 'price_sell_web': p.priceSellWeb,
    'tax_rate': p.taxRate,
    'stock_qty': p.stockQty, 'stock_min_alert': p.stockMinAlert,
    'status': p.status.key,
    'is_active': p.isActive, 'is_visible_web': p.isVisibleWeb,
    'image_url': p.imageUrl, 'rating': p.rating,
    'variants': p.variants.map(_variantToMap).toList(),
    'expenses': p.expenses,
    'created_at': p.createdAt?.toIso8601String(),
  };

  static Product _productFromMap(Map<String, dynamic> m) {
    final rawVariants = m['variants'] as List?;
    // Migration automatique : si aucune variante sauvegardée,
    // créer une variante de base depuis les champs du produit
    List<ProductVariant> variants;
    if (rawVariants != null && rawVariants.isNotEmpty) {
      variants = rawVariants
          .map((v) => _variantFromMap(Map<String, dynamic>.from(v)))
          .toList();
    } else {
      // Ancien produit sans variantes → créer variante de base
      variants = [
        ProductVariant(
          id:           'var_base_${m['id'] ?? '0'}',
          name:         m['name'] as String? ?? 'Base',
          sku:          m['sku'] as String?,
          barcode:      m['barcode'] as String?,
          supplier:     null,
          supplierRef:  null,
          priceBuy:     (m['price_buy'] as num?)?.toDouble() ?? 0,
          priceSellPos: (m['price_sell_pos'] as num?)?.toDouble() ?? 0,
          priceSellWeb: (m['price_sell_web'] as num?)?.toDouble() ?? 0,
          stockAvailable: m['stock_qty'] as int? ?? 0,
          stockPhysical:  m['stock_qty'] as int? ?? 0,
          stockMinAlert: m['stock_min_alert'] as int? ?? 1,
          imageUrl:     m['image_url'] as String?,
          isMain:       true,
        ),
      ];
    }
    return Product(
      id:           m['id'],
      storeId:      m['store_id'],
      categoryId:   m['category_id'],
      brand:        m['brand'],
      name:         m['name'],
      description:  m['description'],
      barcode:      m['barcode'],
      sku:          m['sku'],
      priceBuy:     (m['price_buy'] as num?)?.toDouble() ?? 0,
      customsFee:   (m['customs_fee'] as num?)?.toDouble() ?? 0,
      priceSellPos: (m['price_sell_pos'] as num?)?.toDouble() ?? 0,
      priceSellWeb: (m['price_sell_web'] as num?)?.toDouble() ?? 0,
      taxRate:      (m['tax_rate'] as num?)?.toDouble() ?? 0,
      stockQty:     m['stock_qty'] as int? ?? 0,
      stockMinAlert: m['stock_min_alert'] as int? ?? 5,
      status:       ProductStatusX.fromString(m['status'] as String?),
      isActive:     m['is_active'] as bool? ?? true,
      isVisibleWeb: m['is_visible_web'] as bool? ?? false,
      imageUrl:     m['image_url'],
      rating:       m['rating'] as int? ?? 0,
      variants:     variants,
      expenses:     (m['expenses'] as List?)
          ?.map((e) => Map<String, dynamic>.from(e as Map))
          .toList() ?? [],
      createdAt:    m['created_at'] is String
          ? DateTime.tryParse(m['created_at'] as String)
          : (m['created_at'] is DateTime
              ? m['created_at'] as DateTime
              : null),
    );
  }

  static Map<String, dynamic> _variantToMap(ProductVariant v) => {
    'id': v.id, 'name': v.name, 'sku': v.sku,
    'barcode': v.barcode, 'supplier': v.supplier, 'supplier_ref': v.supplierRef,
    'price_buy': v.priceBuy, 'price_sell_pos': v.priceSellPos,
    'price_sell_web': v.priceSellWeb,
    // 4 champs stock
    'stock_ordered':   v.stockOrdered,
    'stock_physical':  v.stockPhysical,
    'stock_available': v.stockAvailable,
    'stock_blocked':   v.stockBlocked,
    // Rétrocompat : garder stock_qty pour les anciens lecteurs
    'stock_qty': v.stockAvailable,
    'stock_min_alert': v.stockMinAlert,
    'image_url': v.imageUrl,
    'secondary_image_urls': v.secondaryImageUrls,
    'is_main': v.isMain,
    'promo_enabled': v.promoEnabled,
    'promo_price': v.promoPrice,
    'promo_start': v.promoStart?.toIso8601String(),
    'promo_end':   v.promoEnd?.toIso8601String(),
  };

  static ProductVariant _variantFromMap(Map<String, dynamic> m) {
    // Rétrocompat : si stock_available n'existe pas, migrer depuis stock_qty
    final legacy = m['stock_qty'] as int? ?? 0;
    return ProductVariant(
      id:             m['id'],
      name:           m['name'] ?? '',
      sku:            m['sku'],
      barcode:        m['barcode'],
      supplier:       m['supplier'],
      supplierRef:    m['supplier_ref'],
      priceBuy:       (m['price_buy'] as num?)?.toDouble() ?? 0,
      priceSellPos:   (m['price_sell_pos'] as num?)?.toDouble() ?? 0,
      priceSellWeb:   (m['price_sell_web'] as num?)?.toDouble() ?? 0,
      stockOrdered:   m['stock_ordered'] as int? ?? 0,
      stockPhysical:  m['stock_physical'] as int? ?? (m['stock_available'] as int? ?? legacy),
      stockAvailable: m['stock_available'] as int? ?? legacy,
      stockBlocked:   m['stock_blocked'] as int? ?? 0,
      stockMinAlert:  m['stock_min_alert'] as int? ?? 1,
      imageUrl:       m['image_url'] as String?,
      secondaryImageUrls: (m['secondary_image_urls'] as List?)
          ?.map((e) => e as String).toList() ?? [],
      isMain:         m['is_main'] as bool? ?? false,
      promoEnabled:   m['promo_enabled'] as bool? ?? false,
      promoPrice:     (m['promo_price'] as num?)?.toDouble(),
      promoStart:     m['promo_start'] != null
          ? DateTime.tryParse(m['promo_start'] as String) : null,
      promoEnd:       m['promo_end'] != null
          ? DateTime.tryParse(m['promo_end'] as String) : null,
    );
  }

  static UserRole _roleFrom(String s) =>
      UserRole.values.firstWhere((r) => r.name == s,
          orElse: () => UserRole.cashier);

  // ── Boutique active — persistance du dernier choix ─────────────────────────
  static void saveActiveShopId(String userId, String? shopId) {
    if (shopId == null) {
      HiveBoxes.settingsBox.delete('active_shop_$userId');
    } else {
      HiveBoxes.settingsBox.put('active_shop_$userId', shopId);
    }
  }

  static String? getActiveShopId(String userId) =>
      HiveBoxes.settingsBox.get('active_shop_$userId') as String?;


  /// Vérifie si un utilisateur est propriétaire d'une boutique
  /// En lisant directement dans HiveBoxes.shopsBox
  static bool isShopOwner(String? userId, String shopId) {
    if (userId == null) return false;
    try {
      final raw = HiveBoxes.shopsBox.get(shopId);
      if (raw == null) return false;
      final m = Map<String, dynamic>.from(raw as Map);
      return m['owner_id']?.toString() == userId;
    } catch (_) {
      return false;
    }
  }

  // ── Méthodes publiques pour AppDatabase ───────────────────────────────────
  static Map<String, dynamic> productToMap(Product p) => _productToMap(p);
  static Map<String, dynamic> variantToMap(ProductVariant v) => _variantToMap(v);
  static ProductVariant variantFromMap(Map<String, dynamic> m) => _variantFromMap(m);
  static Product productFromMap(Map<String, dynamic> m) => _productFromMap(m);
  // ── Réinitialisation complète des données locales ────────────────────────
  static Future<void> clearAllLocalData() async {
    await HiveBoxes.shopsBox.clear();
    await HiveBoxes.productsBox.clear();
    await HiveBoxes.membershipsBox.clear();
    await HiveBoxes.usersBox.clear();
    await HiveBoxes.settingsBox.clear();
    await HiveBoxes.cartBox.clear();
  }
}