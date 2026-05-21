import '../../../../core/services/export_models.dart';
import '../../../../core/storage/hive_boxes.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../domain/entities/product.dart';
import '../../domain/entities/stock_level.dart';
import '../../domain/entities/stock_location.dart';

/// Source de données pour l'export Produits — purement offline (Hive).
///
/// Lecture seule : ne touche jamais Supabase directement. Les caches
/// `productsBox` / `stockLevelsBox` / `stockLocationsBox` sont
/// maintenus à jour par AppDatabase via Realtime, donc l'export
/// renvoie les mêmes valeurs que l'écran inventaire au même instant.
///
/// Aucune permission n'est vérifiée ici — `canExportProducts` doit
/// avoir été contrôlé par l'UI avant l'appel (la page exports le fait
/// avant d'ouvrir le scope selector).
class ProductsExportSource {
  const ProductsExportSource._();

  /// Header CSV/PDF — 9 colonnes spec PR-1.
  static const List<String> header = [
    'Nom',
    'SKU',
    'Catégorie',
    'Prix vente',
    'Prix achat',
    'Stock disponible',
    'Stock physique',
    'Emplacement',
    'Visible web',
  ];

  /// Collecte les lignes selon le périmètre [scope].
  ///
  /// * `ExportScopeShop`    — tous les produits de la boutique. Stock
  ///   = totaux agrégés (toutes locations confondues). Emplacement =
  ///   liste des locations distinctes où le produit a du stock > 0.
  /// * `ExportScopePartner` — uniquement les produits ayant du stock
  ///   au dépôt partenaire ciblé. Stock = somme par variante à CETTE
  ///   location. Emplacement = nom du partenaire.
  /// * `ExportScopeGlobal`  — itère toutes les boutiques accessibles
  ///   à l'utilisateur. Une ligne par (produit × shop). Emplacement
  ///   est suffixé du nom de boutique pour éviter les ambiguïtés.
  static List<List<Object?>> collect(ExportScope scope) {
    return switch (scope) {
      ExportScopeShop(:final shopId)        => _collectShop(shopId),
      ExportScopePartner(:final shopId, :final locationId) =>
          _collectPartner(shopId, locationId),
      ExportScopeGlobal()                    => _collectGlobal(),
    };
  }

  // ── Shop scope ─────────────────────────────────────────────────

  static List<List<Object?>> _collectShop(String shopId) {
    final products = LocalStorageService.getProductsForShop(shopId)
        .where((p) => !p.isDeleted)
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final locationsById = _locationsById();
    final levelsByVariant = _stockLevelsByVariant(shopId);
    return [
      for (final p in products) _rowForShop(p, locationsById, levelsByVariant),
    ];
  }

  static List<Object?> _rowForShop(
    Product p,
    Map<String, StockLocation> locationsById,
    Map<String, List<StockLevel>> levelsByVariant,
  ) {
    // Locations distinctes où le produit a du stock disponible.
    final locs = <String>{};
    for (final v in p.variants) {
      final vid = v.id;
      if (vid == null) continue;
      for (final lvl in levelsByVariant[vid] ?? const <StockLevel>[]) {
        if (lvl.stockAvailable <= 0 && lvl.stockPhysical <= 0) continue;
        final loc = locationsById[lvl.locationId];
        if (loc != null) locs.add(loc.name);
      }
    }
    final locLabel = locs.isEmpty ? 'Boutique' : locs.join(' · ');
    return [
      p.name,
      p.sku ?? '',
      p.categoryId ?? '',
      p.priceSellPos,
      p.priceBuy,
      p.totalStock,
      p.totalPhysical,
      locLabel,
      p.isVisibleWeb ? 'Oui' : 'Non',
    ];
  }

  // ── Partner scope ──────────────────────────────────────────────

  static List<List<Object?>> _collectPartner(
      String shopId, String locationId) {
    final loc = _locationsById()[locationId];
    final partnerName = loc?.name ?? 'Partenaire';
    final products = LocalStorageService.getProductsForShop(shopId)
        .where((p) => !p.isDeleted);
    final levelsByVariant = _stockLevelsByVariant(shopId);
    final rows = <List<Object?>>[];
    for (final p in products) {
      int available = 0;
      int physical  = 0;
      for (final v in p.variants) {
        final vid = v.id;
        if (vid == null) continue;
        for (final lvl in levelsByVariant[vid] ?? const <StockLevel>[]) {
          if (lvl.locationId != locationId) continue;
          available += lvl.stockAvailable;
          physical  += lvl.stockPhysical;
        }
      }
      // Filtre : on n'inclut que les produits réellement présents au
      // dépôt partenaire — sinon l'export est pollué par tout le
      // catalogue de la boutique.
      if (available == 0 && physical == 0) continue;
      rows.add([
        p.name,
        p.sku ?? '',
        p.categoryId ?? '',
        p.priceSellPos,
        p.priceBuy,
        available,
        physical,
        partnerName,
        p.isVisibleWeb ? 'Oui' : 'Non',
      ]);
    }
    rows.sort((a, b) => (a[0] as String)
        .toLowerCase()
        .compareTo((b[0] as String).toLowerCase()));
    return rows;
  }

  // ── Global scope ───────────────────────────────────────────────

  static List<List<Object?>> _collectGlobal() {
    final me = LocalStorageService.getCurrentUser();
    if (me == null) return const [];
    final shops = LocalStorageService.getShopsForUser(me.id);
    final locationsById = _locationsById();
    final rows = <List<Object?>>[];
    for (final s in shops) {
      final levelsByVariant = _stockLevelsByVariant(s.id);
      final products = LocalStorageService.getProductsForShop(s.id)
          .where((p) => !p.isDeleted);
      for (final p in products) {
        final base = _rowForShop(p, locationsById, levelsByVariant);
        // Suffixe l'emplacement par le nom de boutique pour qu'une
        // même catégorie/produit appartenant à 2 shops reste lisible
        // dans le CSV agrégé.
        base[7] = '${s.name} — ${base[7]}';
        rows.add(base);
      }
    }
    rows.sort((a, b) => (a[0] as String)
        .toLowerCase()
        .compareTo((b[0] as String).toLowerCase()));
    return rows;
  }

  // ── Helpers de lecture Hive ────────────────────────────────────

  static Map<String, StockLocation> _locationsById() {
    final box = HiveBoxes.stockLocationsBox;
    final out = <String, StockLocation>{};
    for (final raw in box.values) {
      try {
        final loc = StockLocation.fromMap(Map<String, dynamic>.from(raw));
        out[loc.id] = loc;
      } catch (_) {/* skip rows mal formés */}
    }
    return out;
  }

  /// Index variantId → stock_levels. Filtré par shopId quand le champ
  /// dénormalisé est renseigné (sinon on inclut tous les niveaux —
  /// la croisée avec les variantes du produit limite déjà au shop).
  static Map<String, List<StockLevel>> _stockLevelsByVariant(String shopId) {
    final box = HiveBoxes.stockLevelsBox;
    final out = <String, List<StockLevel>>{};
    for (final raw in box.values) {
      try {
        final lvl = StockLevel.fromMap(Map<String, dynamic>.from(raw));
        if (lvl.shopId != null && lvl.shopId != shopId) continue;
        (out[lvl.variantId] ??= <StockLevel>[]).add(lvl);
      } catch (_) {/* skip */}
    }
    return out;
  }

  /// Liste des dépôts partenaires de la boutique [shopId] — sert au
  /// scope selector pour peupler le dropdown.
  static List<StockLocation> partnerLocationsForShop(String shopId) {
    // Les locations partner sont rattachées à l'`ownerId` du shop (pas
    // au shopId direct) : un partenaire dessert TOUTES les boutiques
    // du même owner. On filtre par `ownerId == shop.ownerId` plutôt
    // qu'`shopId` strict.
    final shop = LocalStorageService.getShop(shopId);
    if (shop == null) return const [];
    final ownerId = shop.ownerId;
    final out = <StockLocation>[];
    for (final raw in HiveBoxes.stockLocationsBox.values) {
      try {
        final loc = StockLocation.fromMap(Map<String, dynamic>.from(raw));
        if (loc.type != StockLocationType.partner) continue;
        if (loc.ownerId != ownerId) continue;
        if (!loc.isActive) continue;
        out.add(loc);
      } catch (_) {}
    }
    out.sort((a, b) =>
        a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }
}
