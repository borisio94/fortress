import '../../features/caisse/domain/entities/sale_item.dart';
import '../../features/restaurant/domain/entities/restaurant_activity.dart';
import '../storage/local_storage_service.dart';
import 'activity_service.dart';

/// Poste qui prépare un article : cuisine, bar, chawarma…
///
/// [key] est la valeur persistée (colonne `restaurant_activities.station`,
/// préférence d'écran) ; [label] sert aux bons imprimés (lus à bout de bras,
/// donc en capitales) ; [title] à l'interface.
enum ServiceStation {
  cuisine('cuisine', 'CUISINE', 'Cuisine'),
  bar('bar', 'BAR', 'Bar'),
  chawarma('chawarma', 'CHAWARMA', 'Chawarma'),
  glacier('glacier', 'GLACIER', 'Glacier'),
  patisserie('patisserie', 'PÂTISSERIE', 'Pâtisserie'),
  autre('autre', 'AUTRE POSTE', 'Autre poste');

  const ServiceStation(this.key, this.label, this.title);

  final String key;
  final String label;
  final String title;

  /// Poste correspondant à [k], ou `null` si la valeur est absente ou inconnue.
  ///
  /// Ne retombe PAS sur `cuisine` : l'appelant doit pouvoir distinguer « poste
  /// non précisé » (→ déduction par le mode) d'un poste explicite.
  static ServiceStation? fromKey(String? k) {
    final v = (k ?? '').trim().toLowerCase();
    if (v.isEmpty) return null;
    for (final s in ServiceStation.values) {
      if (s.key == v) return s;
    }
    return null;
  }
}

/// Routage des articles d'une tournée vers les postes de service.
///
/// Le poste se déduit du SECTEUR du plat (`products.activity_id`, posé au Lot 1
/// du module finances) :
///
///   1. si le secteur déclare un poste (`restaurant_activities.station`,
///      hotfix_144), c'est lui qui décide — c'est le seul moyen de séparer une
///      pâtisserie d'une cuisine ;
///   2. sinon, on retombe sur le MODE du secteur — `stock` (vendu tel quel :
///      boissons, eaux, bières) → **BAR** ; `recipe` (préparé à la commande) →
///      **CUISINE**. C'est le comportement d'avant hotfix_144, conservé pour
///      que les boutiques déjà en service n'aient rien à reparamétrer ;
///   3. aucun secteur → **CUISINE**, le cas le plus courant et le moins
///      dommageable : un bon qui arrive en cuisine se relaie à la voix, un plat
///      oublié parce qu'il est parti au bar ne sort jamais.
class RoundRouting {
  RoundRouting._();

  static ServiceStation stationFor(String shopId, String productId) {
    try {
      final p = LocalStorageService.getProduct(productId);
      final activityId = p?.activityId;
      if (activityId == null || activityId.isEmpty) {
        return ServiceStation.cuisine;
      }
      return resolve(ActivityService.byId(shopId, activityId));
    } catch (_) {
      return ServiceStation.cuisine;
    }
  }

  /// LA RÈGLE de routage, isolée de Hive pour être testable : poste déclaré
  /// s'il existe, sinon déduction par le mode, sinon cuisine.
  static ServiceStation resolve(RestaurantActivity? activity) {
    if (activity == null) return ServiceStation.cuisine;
    final explicit = ServiceStation.fromKey(activity.station);
    if (explicit != null) return explicit;
    return activity.isStockMode ? ServiceStation.bar : ServiceStation.cuisine;
  }

  /// Articles regroupés par poste, dans l'ordre d'apparition.
  static Map<ServiceStation, List<SaleItem>> split(
      String shopId, List<SaleItem> items) {
    final byStation = <ServiceStation, List<SaleItem>>{};
    for (final item in items) {
      final station = stationFor(shopId, item.productId);
      byStation.putIfAbsent(station, () => []).add(item);
    }
    return byStation;
  }

  /// Postes concernés par une tournée, dans l'ordre de déclaration de l'enum
  /// (et non d'apparition des articles) : l'en-tête d'un ticket ne doit pas
  /// changer d'ordre parce que le serveur a saisi la bière avant le plat.
  static List<ServiceStation> stationsOf(String shopId, List<SaleItem> items) {
    final found = split(shopId, items).keys.toSet();
    return ServiceStation.values.where(found.contains).toList();
  }

  /// Articles de [items] qui reviennent à [station].
  static List<SaleItem> itemsFor(
          String shopId, List<SaleItem> items, ServiceStation station) =>
      items
          .where((i) => stationFor(shopId, i.productId) == station)
          .toList();
}
