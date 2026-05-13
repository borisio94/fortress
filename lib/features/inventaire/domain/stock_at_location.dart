import '../../../core/database/app_database.dart';
import '../../../core/storage/hive_boxes.dart';
import '../../../core/storage/local_storage_service.dart';
import 'entities/product.dart';
import 'entities/stock_location.dart';

/// Résout un `viewFilter` (du `dashViewFilterProvider`) en liste d'IDs
/// de `stock_locations`. Pilote l'affichage du stock dans plusieurs
/// surfaces (inventaire, dashboard, partage catalogue).
///
/// Conventions :
/// * `null` (vue Globale) → tous les emplacements actifs de l'owner
///   (boutique(s) `type='shop'` rattachée(s) au shop + partenaires
///   `type='partner'` du même owner). Permet de SOMMER boutique +
///   partenaires plutôt que retomber sur `Product.totalStock` qui ne
///   lit que la boutique.
/// * `'_base'` (vue Boutique seule) → uniquement les `type='shop'` du
///   shop courant.
/// * sinon (vue Partenaire spécifique) → liste contenant uniquement
///   l'ID passé.
///
/// Logique extraite de `inventaire_page.dart` pour pouvoir être réutilisée
/// par `dashboard_page.dart` au moment du partage catalogue (sprint
/// « snapshot stock filtré dans l'URL »).
List<String>? resolveLocationIds(String? viewFilter, String shopId) {
  if (viewFilter == null) {
    final shop = LocalStorageService.getShop(shopId);
    final ownerId = shop?.ownerId;
    final ids = <String>[];
    for (final raw in HiveBoxes.stockLocationsBox.values) {
      try {
        final loc = StockLocation.fromMap(Map<String, dynamic>.from(raw));
        if (!loc.isActive) continue;
        final isShopLoc = loc.shopId == shopId
            && loc.type == StockLocationType.shop;
        final isOwnerPartner = ownerId != null
            && loc.ownerId == ownerId
            && loc.type == StockLocationType.partner;
        if (isShopLoc || isOwnerPartner) ids.add(loc.id);
      } catch (_) {/* skip entrée corrompue */}
    }
    return ids.isEmpty ? null : ids;
  }
  if (viewFilter == '_base') {
    final ids = <String>[];
    for (final raw in HiveBoxes.stockLocationsBox.values) {
      try {
        final loc = StockLocation.fromMap(Map<String, dynamic>.from(raw));
        if (loc.shopId == shopId
            && loc.type == StockLocationType.shop
            && loc.isActive) {
          ids.add(loc.id);
        }
      } catch (_) {/* skip */}
    }
    return ids;
  }
  return [viewFilter];
}

/// Stock total d'un produit calculé sur les `locationIds` fournis.
/// Si la liste est `null` ou vide → on retombe sur `product.totalStock`.
int stockAtLocations(Product p, List<String>? locationIds) {
  if (locationIds == null || locationIds.isEmpty) return p.totalStock;
  if (p.variants.isEmpty) return 0;
  var total = 0;
  for (final v in p.variants) {
    final id = v.id;
    if (id == null) continue;
    for (final locId in locationIds) {
      total += AppDatabase.getStockLevel(id, locId)?.stockAvailable ?? 0;
    }
  }
  return total;
}

/// Stock d'une variante précise sur les `locationIds` fournis.
/// Si la liste est `null` ou vide → on retombe sur `variant.stockAvailable`
/// (= stock global persisté côté variant, somme implicite des locations
/// pour les implémentations qui ne tiennent pas la table stock_levels).
int stockForVariantAtLocations(
    ProductVariant v, List<String>? locationIds) {
  if (locationIds == null || locationIds.isEmpty) return v.stockAvailable;
  final id = v.id;
  if (id == null) return 0;
  var total = 0;
  for (final locId in locationIds) {
    total += AppDatabase.getStockLevel(id, locId)?.stockAvailable ?? 0;
  }
  return total;
}
