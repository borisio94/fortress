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
/// **Granularité variante** : un produit `simple` (sans variants) ⇒
/// une ligne ; un produit `variant` (taille, couleur, …) ⇒ une ligne
/// par variante avec SKU/stock/prix propres. Le nom est suffixé du
/// libellé variante (`T-shirt — Rouge L`) pour rester lisible.
///
/// Aucune permission n'est vérifiée ici — `canExportProducts` doit
/// avoir été contrôlé par l'UI avant l'appel.
class ProductsExportSource {
  const ProductsExportSource._();

  /// Header CSV/PDF — 10 colonnes spec PR-1 + variante.
  static const List<String> header = [
    'Produit',
    'Variante',
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
  ///   = totaux agrégés (toutes locations) PAR variante.
  ///   Emplacement = liste des locations où la variante a du stock > 0.
  /// * `ExportScopePartner` — uniquement les variantes ayant du stock
  ///   au dépôt partenaire ciblé. Stock = somme à CETTE location.
  ///   Emplacement = nom du partenaire.
  /// * `ExportScopeGlobal`  — itère toutes les boutiques accessibles
  ///   à l'utilisateur. Emplacement préfixé du nom de boutique.
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
      ..sort((a, b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final locationsById = _locationsById();
    final levelsByVariant = _stockLevelsByVariant(shopId);
    final rows = <List<Object?>>[];
    for (final p in products) {
      rows.addAll(_rowsForProductShop(p, locationsById, levelsByVariant));
    }
    return rows;
  }

  /// Une ligne par variante ; pour un produit sans variants, une seule
  /// ligne qui agrège les totaux Product.
  static List<List<Object?>> _rowsForProductShop(
    Product p,
    Map<String, StockLocation> locationsById,
    Map<String, List<StockLevel>> levelsByVariant,
  ) {
    if (p.variants.isEmpty) {
      return [
        [
          p.name,
          '',                        // pas de variante
          p.sku ?? '',
          p.categoryId ?? '',
          p.priceSellPos,
          p.priceBuy,
          p.totalStock,
          p.totalPhysical,
          'Boutique',
          p.isVisibleWeb ? 'Oui' : 'Non',
        ]
      ];
    }
    final rows = <List<Object?>>[];
    for (final v in p.variants) {
      final vid    = v.id;
      final levels = vid == null
          ? const <StockLevel>[]
          : (levelsByVariant[vid] ?? const <StockLevel>[]);
      // Emplacements où cette variante a du stock > 0.
      final locs = <String>{};
      for (final lvl in levels) {
        if (lvl.stockAvailable <= 0 && lvl.stockPhysical <= 0) continue;
        final loc = locationsById[lvl.locationId];
        if (loc != null) locs.add(loc.name);
      }
      final locLabel = locs.isEmpty ? 'Boutique' : locs.join(' · ');
      rows.add([
        p.name,
        v.name,
        v.sku ?? p.sku ?? '',
        p.categoryId ?? '',
        // Prix : on prend les prix de la variante quand renseignés, sinon
        // ceux du produit parent (variantes héritent des prix produit
        // tant qu'elles ne sont pas overridées dans le formulaire).
        v.priceSellPos > 0 ? v.priceSellPos : p.priceSellPos,
        v.priceBuy     > 0 ? v.priceBuy     : p.priceBuy,
        v.stockAvailable,
        v.stockPhysical,
        locLabel,
        p.isVisibleWeb ? 'Oui' : 'Non',
      ]);
    }
    return rows;
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
      if (p.variants.isEmpty) {
        // Produit simple sans variante : on ne peut pas le mapper sur
        // un stock_level (qui est par variantId). On agrège sur tous
        // les niveaux de la même shop dont locationId match.
        // Pas d'inclusion par défaut — un produit simple "sur partenaire"
        // doit avoir une variante implicite côté data (voir migration
        // multi-location). On l'exclut donc pour rester cohérent avec
        // l'écran Inventaire qui ne le montre pas non plus dans la vue
        // partenaire.
        continue;
      }
      for (final v in p.variants) {
        final vid = v.id;
        if (vid == null) continue;
        int available = 0;
        int physical  = 0;
        for (final lvl in levelsByVariant[vid] ?? const <StockLevel>[]) {
          if (lvl.locationId != locationId) continue;
          available += lvl.stockAvailable;
          physical  += lvl.stockPhysical;
        }
        if (available == 0 && physical == 0) continue;
        rows.add([
          p.name,
          v.name,
          v.sku ?? p.sku ?? '',
          p.categoryId ?? '',
          v.priceSellPos > 0 ? v.priceSellPos : p.priceSellPos,
          v.priceBuy     > 0 ? v.priceBuy     : p.priceBuy,
          available,
          physical,
          partnerName,
          p.isVisibleWeb ? 'Oui' : 'Non',
        ]);
      }
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
        final productRows =
            _rowsForProductShop(p, locationsById, levelsByVariant);
        for (final r in productRows) {
          // Préfixe le nom du produit par le nom de la boutique pour
          // distinguer 2 catalogues homonymes dans le CSV agrégé.
          r[0] = '${s.name} — ${r[0]}';
          // Suffixe l'emplacement pour la même raison.
          r[8] = '${s.name} — ${r[8]}';
          rows.add(r);
        }
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
  /// dénormalisé est renseigné.
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
    // du même owner.
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
