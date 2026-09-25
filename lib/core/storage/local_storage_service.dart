import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'hive_boxes.dart';
import 'schema_migrator.dart';
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

  /// Propriétaire des données locales actuellement en cache (anti-fuite
  /// inter-comptes sur appareil partagé). Posé au login, EFFACÉ au logout
  /// (volontairement absent de `_deviceSettingKeys`). Au login suivant, si ce
  /// marqueur diffère du nouvel utilisateur, c'est qu'un logout n'a pas eu
  /// lieu/fini → on purge avant de charger (cf. AuthSupabaseDataSource.login).
  static String? getLocalDataOwnerId() =>
      HiveBoxes.settingsBox.get('local_data_owner_id') as String?;

  static Future<void> setLocalDataOwnerId(String id) =>
      HiveBoxes.settingsBox.put('local_data_owner_id', id);

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
    if (m == null) return null;
    try {
      return _shopFromMap(Map<String, dynamic>.from(m));
    } catch (e) {
      // Une map Hive corrompue (champ inattendu, cast impossible) ne doit
      // jamais casser le provider qui lit la boutique active — sinon
      // toute la page paramètres reste bloquée sur un spinner. On log et
      // on retourne null : l'appelant fera un fallback / refetch réseau.
      // Erreur silencieuse acceptable car ce chemin est doublé par le
      // refetch Supabase au prochain `syncShops`.
      // ignore: avoid_print
      // (debugPrint déjà disponible via flutter/foundation côté caller)
      return null;
    }
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
  // POSTES — par boutique (hotfix_160)
  // ══════════════════════════════════════════════════════════════════
  //
  // Les fonctions proposées à la création d'un compte : Serveur, Cuisinier,
  // Livreur… Même stockage que les marques et les unités — une simple liste
  // de libellés par boutique, tenue à jour depuis Supabase par
  // `AppDatabase.syncMetadata`.
  //
  // La clé `job_titles_<shopId>` était déjà utilisée AVANT hotfix_160 pour
  // ranger les seuls ajouts manuels de l'appareil. Ils ne sont pas perdus :
  // `AppDatabase.ensureJobTitlesSeeded` les reprend dans la liste partagée
  // au premier amorçage.

  static List<String> getJobTitles(String shopId) {
    final raw = HiveBoxes.settingsBox.get('job_titles_$shopId');
    if (raw == null) return [];
    return List<String>.from(raw as List);
  }

  /// Profil de droits par poste : nom du poste → clés de permissions séparées
  /// par des virgules (hotfix_161). Un poste absent de cette table ne décide
  /// d'aucun accès — le choisir ne coche ni ne décoche rien.
  static Map<String, String> getJobTitlePerms(String shopId) {
    final raw = HiveBoxes.settingsBox.get('job_title_perms_$shopId');
    if (raw is! Map) return {};
    return raw.map((k, v) => MapEntry(k.toString(), v?.toString() ?? ''));
  }

  /// Taux horaire des heures supplémentaires par poste (hotfix_165), en FCFA.
  ///
  /// Un poste absent vaut 0 : ses heures supplémentaires sont comptées en
  /// minutes mais jamais valorisées. C'est volontaire — mieux vaut un montant
  /// nul et visible qu'un taux inventé par l'application.
  static Map<String, int> getJobTitleRates(String shopId) {
    final raw = HiveBoxes.settingsBox.get('job_title_rates_$shopId');
    if (raw is! Map) return {};
    final out = <String, int>{};
    raw.forEach((k, v) {
      final n = v is num ? v.toInt() : int.tryParse(v?.toString() ?? '');
      if (n != null) out[k.toString()] = n;
    });
    return out;
  }

  /// Heure de fermeture de l'établissement, `HH:mm` — `null` si aucune n'est
  /// réglée, auquel cas aucun départ n'est jugé.
  static String? getShopClosingTime(String shopId) {
    final raw = HiveBoxes.settingsBox.get('staff_closing_time_$shopId');
    final s = raw?.toString().trim() ?? '';
    return s.isEmpty ? null : s;
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
        // hotfix_085 : on filtre les soft-deleted dès la lecture Hive,
        // symétrique avec la RLS Supabase qui les cache aux membres.
        // L'écran super-admin lit directement Supabase (pas via cette
        // fonction) pour les voir.
        .where((p) => p.storeId == shopId && !p.isDeleted)
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    _productsCache[shopId] = list;
    return list;
  }

  /// Lit un produit par id. Filtre les soft-deleted par défaut. Passer
  /// [includeDeleted] = true pour les inclure (utile au `DeleteProductUseCase`
  /// qui doit relire l'état pré-suppression, ou aux écrans super-admin).
  static Product? getProduct(String id, {bool includeDeleted = false}) {
    final m = HiveBoxes.productsBox.get(id);
    if (m == null) return null;
    final p = _productFromMap(Map<String, dynamic>.from(m));
    if (!includeDeleted && p.isDeleted) return null;
    return p;
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

  // Schema versioning (cf. lib/core/storage/schema_migrator.dart).
  // Chaque entité a son propre migrator pour pouvoir évoluer indépendamment.
  static final _userMigrator = SchemaMigrator(
    currentVersion: 1, steps: const {});
  static final _shopMigrator = SchemaMigrator(
    currentVersion: 1, steps: const {});

  static Map<String, dynamic> _userToMap(User u) => {
    'schema_version': _userMigrator.currentVersion,
    'id': u.id, 'email': u.email, 'name': u.name,
    'phone': u.phone, 'avatar_url': u.avatarUrl,
    'created_at': u.createdAt.toIso8601String(),
  };

  static User _userFromMap(Map<String, dynamic> rawM) {
    final m = _userMigrator.migrate(rawM);
    return User(
      id: m['id'], email: m['email'], name: m['name'],
      phone: m['phone'], avatarUrl: m['avatar_url'],
      createdAt: DateTime.parse(m['created_at']),
    );
  }

  static Map<String, dynamic> _shopToMap(ShopSummary s) => {
    'schema_version': _shopMigrator.currentVersion,
    'id': s.id, 'name': s.name, 'logo_url': s.logoUrl,
    'currency': s.currency, 'country': s.country, 'sector': s.sector,
    'is_active': s.isActive, 'today_sales': s.todaySales,
    'owner_id': s.ownerId, 'phone': s.phone,
    'whatsapp_phone': s.whatsappPhone, 'email': s.email,
    'facebook_pixel_id': s.facebookPixelId,
    'partner_debt_alert_days': s.partnerDebtAlertDays,
    'service_late_send_min':    s.serviceLateSendMin,
    'service_late_kitchen_min': s.serviceLateKitchenMin,
    'service_late_pass_min':    s.serviceLatePassMin,
    'created_at': s.createdAt?.toIso8601String(),
    'kind':           s.kind.key,
    'parent_shop_id': s.parentShopId,
    'status':           s.status,
    'suspended_at':     s.suspendedAt?.toIso8601String(),
    'suspended_reason': s.suspendedReason,
  };

  static ShopSummary _shopFromMap(Map<String, dynamic> rawM) {
    final m = _shopMigrator.migrate(rawM);
    return ShopSummary(
    // Lectures DEFENSIVES : on accepte n'importe quel type dans la map
    // (legacy formats, payloads tronqués par anciens `_shopToMap`,
    // valeurs nulles inattendues). Tout cast strict (`as String`) sur un
    // champ manquant casserait le `currentShopProvider` au build et
    // bloquerait la page paramètres sur un spinner.
    id:           (m['id']        ?? '').toString(),
    name:         (m['name']      ?? '').toString(),
    logoUrl:      m['logo_url']?.toString(),
    currency:     (m['currency']  ?? 'XAF').toString(),
    country:      (m['country']   ?? 'CM').toString(),
    sector:       (m['sector']    ?? 'retail').toString(),
    isActive:     m['is_active']  as bool? ?? true,
    todaySales:   (m['today_sales'] as num?)?.toDouble(),
    ownerId:      m['owner_id']?.toString(),
    phone:        m['phone']?.toString(),
    whatsappPhone: m['whatsapp_phone']?.toString(),
    email:        m['email']?.toString(),
    facebookPixelId: m['facebook_pixel_id']?.toString(),
    // Champ ajouté après coup : toute map écrite par une version antérieure
    // en est dépourvue. Le défaut suffit, aucune migration n'est requise —
    // c'est précisément ce que la lecture défensive permet d'éviter.
    partnerDebtAlertDays:
        (m['partner_debt_alert_days'] as num?)?.toInt() ?? 30,
    // hotfix_183 — même lecture défensive : absent d'une map antérieure.
    serviceLateSendMin: (m['service_late_send_min'] as num?)?.toInt() ??
        kServiceLateSendDefault,
    serviceLateKitchenMin: (m['service_late_kitchen_min'] as num?)?.toInt() ??
        kServiceLateKitchenDefault,
    serviceLatePassMin: (m['service_late_pass_min'] as num?)?.toInt() ??
        kServiceLatePassDefault,
    createdAt:    m['created_at'] is String
        ? DateTime.tryParse(m['created_at'] as String)
        : (m['created_at'] is DateTime
            ? m['created_at'] as DateTime
            : null),
    kind:         ShopKindX.fromKey(m['kind']?.toString()),
    parentShopId: m['parent_shop_id']?.toString(),
    status:          (m['status'] ?? 'active').toString(),
    suspendedAt:     m['suspended_at'] is String
        ? DateTime.tryParse(m['suspended_at'] as String) : null,
    suspendedReason: m['suspended_reason']?.toString(),
    );
  }

  // ───────────────────────────────────────────────────────────────────
  // Migration versionnée Product (cf. lib/core/storage/schema_migrator.dart).
  //
  // Convention : chaque fois qu'on modifie le format sérialisé de Product
  // (renommer un champ, changer une valeur par défaut, etc.), on :
  //   1. Bump `currentVersion`
  //   2. Ajoute une step `N: (m) => transformed_m` dans `steps`
  // Les anciens produits stockés en Hive/Supabase seront migrés à la
  // lecture, transparent pour l'utilisateur final. Pour persister la
  // migration côté serveur, le write-back via `saveProduct` ré-écrit le
  // map migré (avec `schema_version: currentVersion`).
  static final _productMigrator = SchemaMigrator(
    currentVersion: 1,
    steps: const {
      // Exemple pour la prochaine évolution :
      // 1: _migrateProductV1ToV2,
    },
  );

  // Exemple commenté d'une future migration :
  // static Map<String, dynamic> _migrateProductV1ToV2(
  //     Map<String, dynamic> m) {
  //   // v1 → v2 : `price` devient `price_buy` (clarification).
  //   if (m.containsKey('price') && !m.containsKey('price_buy')) {
  //     m['price_buy'] = m['price'];
  //     m.remove('price');
  //   }
  //   return m;
  // }

  static Map<String, dynamic> _productToMap(Product p) => {
    'schema_version': _productMigrator.currentVersion,
    'id': p.id, 'store_id': p.storeId, 'category_id': p.categoryId,
    'brand': p.brand, 'name': p.name, 'description': p.description,
    'barcode': p.barcode, 'sku': p.sku,
    'price_buy': p.priceBuy, 'customs_fee': p.customsFee,
    'price_sell_pos': p.priceSellPos, 'price_sell_web': p.priceSellWeb,
    'tax_rate': p.taxRate,
    'stock_qty': p.stockQty, 'stock_min_alert': p.stockMinAlert,
    'status': p.status.key,
    'is_active': p.isActive, 'is_visible_web': p.isVisibleWeb,
    'track_stock': p.trackStock,
    'activity_id': p.activityId,
    'image_url': p.imageUrl, 'rating': p.rating,
    'variants': p.variants.map(_variantToMap).toList(),
    'expenses': p.expenses,
    'created_at': p.createdAt?.toIso8601String(),
    'draft_expires_at': p.draftExpiresAt?.toIso8601String(),
    'unit': p.unit, 'internal_notes': p.internalNotes,
    // Soft-delete (hotfix_085). archived_snapshot reste null pour les
    // produits vivants — il est rempli uniquement par la RPC delete_product
    // côté serveur et redescendu via realtime.
    'deleted_at':        p.deletedAt?.toUtc().toIso8601String(),
    'deleted_by':        p.deletedBy,
    'delete_reason':     p.deleteReason,
    'archived_snapshot': p.archivedSnapshot,
  };

  static Product _productFromMap(Map<String, dynamic> rawM) {
    // Migration automatique : applique les steps successifs pour
    // remettre les anciennes données au format courant. No-op si
    // `schema_version == currentVersion`.
    final m = _productMigrator.migrate(rawM);
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
      // Défaut true : les produits antérieurs à hotfix_138 n'ont pas la clé
      // et doivent conserver le suivi de stock historique.
      trackStock:   m['track_stock'] as bool? ?? true,
      // Secteur restaurant (hotfix_141) — absent des produits legacy et de
      // tout l'e-commerce : null, aucun rattachement.
      activityId:   m['activity_id'] as String?,
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
      // Absent de tous les produits antérieurs → null, donc non-brouillon.
      // Lecture tolérante, comme les champs de suppression douce ci-dessous.
      draftExpiresAt: m['draft_expires_at'] is String
          ? DateTime.tryParse(m['draft_expires_at'] as String)
          : (m['draft_expires_at'] is DateTime
              ? m['draft_expires_at'] as DateTime
              : null),
      // Absents des produits antérieurs → null.
      unit:          m['unit'] as String?,
      internalNotes: m['internal_notes'] as String?,
      // Soft-delete (hotfix_085). Lecture tolérante : les produits legacy
      // n'ont pas ces colonnes → null par défaut.
      deletedAt: m['deleted_at'] is String
          ? DateTime.tryParse(m['deleted_at'] as String)
          : (m['deleted_at'] is DateTime
              ? m['deleted_at'] as DateTime
              : null),
      deletedBy:        m['deleted_by']    as String?,
      deleteReason:     m['delete_reason'] as String?,
      archivedSnapshot: m['archived_snapshot'] is Map
          ? Map<String, dynamic>.from(m['archived_snapshot'] as Map)
          : null,
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
    // Poids et dimensions : dans le JSON des variantes, sans colonne
    // dédiée — il n'existe pas de table `product_variants`.
    'weight_g':  v.weightG,
    'length_cm': v.lengthCm,
    'width_cm':  v.widthCm,
    'height_cm': v.heightCm,
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
      // Absentes des variantes antérieures → null, aucune migration.
      weightG:  (m['weight_g']  as num?)?.toDouble(),
      lengthCm: (m['length_cm'] as num?)?.toDouble(),
      widthCm:  (m['width_cm']  as num?)?.toDouble(),
      heightCm: (m['height_cm'] as num?)?.toDouble(),
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
      final m = Map<String, dynamic>.from(raw);
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
  /// Purge TOUTES les box métier (commandes, clients, ventes, stock, finances,
  /// tickets, notifs, panier…) en conservant les préférences device (thème,
  /// locale, dernier email). Anciennement PARTIELLE (ne vidait que shops/
  /// products/memberships/users/settings/cart) → elle laissait fuiter
  /// commandes et clients lors d'une invalidation de session zombie ou d'une
  /// suppression de compte. Déléguée désormais à la purge complète anti-fuite.
  static Future<void> clearAllLocalData() =>
      HiveBoxes.clearAllForLogout(_deviceSettingKeys,
          preserveSettingsKeyPrefixes: _deviceSettingKeyPrefixes);

  /// Clés de PRÉFÉRENCES liées à l'APPAREIL (pas au compte) — conservées au
  /// logout. Tout le reste (caches compte/boutique `*_$userId`/`*_$shopId`,
  /// `current_user_id`, tokens…) est purgé. Les chaînes sont
  /// les clés posées par : TextScale (`text_scale`), DemoMode
  /// (`demo_mode_enabled`), ThemeMode (`app_theme_mode`), ThemePalette
  /// (`app_theme_palette*`), locale (`app_locale`), onboarding
  /// (`onboarding_seen`), ce service (`last_login_email`, `whatsapp_provider`).
  static const _deviceSettingKeys = <String>{
    'last_login_email',
    'text_scale',
    'demo_mode_enabled',
    'app_theme_mode',
    'app_theme_palette',
    'app_theme_palette_last_manual',
    'app_locale',
    'onboarding_seen',
    'whatsapp_provider',
    // Barre de navigation rétractée : préférence d'AFFICHAGE de l'appareil,
    // au même titre que la taille du texte. La purger au logout rouvrirait la
    // barre déployée à chaque reconnexion.
    'nav_rail_collapsed',
    // `local_data_owner_id` n'est PAS listé ici : ce n'est pas une préférence.
    // `settingKeysToKeepOnLogout` (logout_purge_policy.dart) l'ajoute, et un
    // test l'exige — il décrit l'appareil, pas la session, et sans lui la garde
    // anti-fuite du login lirait `null` et ne se déclencherait jamais.
  };

  /// Préfixes de clés settings conservés au purge (clés dynamiques par uid).
  /// `onboarding_done_<uid>` : le tour de bienvenue est vu UNE FOIS par compte
  /// sur l'appareil — il ne doit pas réapparaître à chaque reconnexion.
  static const _deviceSettingKeyPrefixes = <String>{
    'onboarding_done_',
  };

  /// Purge anti-fuite inter-comptes (appareil partagé) : efface TOUTES les
  /// données locales liées au compte/boutique en conservant les préférences
  /// device ci-dessus. À appeler au logout (remplace `clearCurrentUser`, qui
  /// n'effaçait que `current_user_id` et laissait fuiter produits, prix
  /// d'achat, clients, panier…).
  static Future<void> purgeOnLogout() =>
      HiveBoxes.clearAllForLogout(_deviceSettingKeys,
          preserveSettingsKeyPrefixes: _deviceSettingKeyPrefixes);
}