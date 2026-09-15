import 'package:flutter/foundation.dart' show debugPrint;
import 'package:hive_flutter/hive_flutter.dart';

import '../../features/parametres/domain/entities/delivery_quartier.dart';
import '../../features/parametres/domain/entities/delivery_zone.dart';
import '../database/app_database.dart';
import '../storage/hive_boxes.dart';

/// Service Hive-first pour les frais de livraison par quartier (zones +
/// quartiers). Toute mutation est :
///   1. écrite IMMÉDIATEMENT dans Hive (offline-first),
///   2. notifiée aux listeners (`AppDatabase`) pour rafraîchir l'UI,
///   3. poussée en arrière-plan vers Supabase (file offline si KO).
///
/// Les ids sont générés CÔTÉ CLIENT (`dz_`/`dq_` + microsecondes) pour que la
/// création hors-ligne soit immédiatement utilisable et que Hive ↔ Supabase
/// partagent la même clé (cf. convention partner_ledger_entries).
class DeliveryZoneService {
  DeliveryZoneService._();

  static Box<Map> _zonesRaw() => HiveBoxes.deliveryZonesBox;
  static Box<Map> _quartiersRaw() => HiveBoxes.deliveryQuartiersBox;

  static String _zoneId() => 'dz_${DateTime.now().microsecondsSinceEpoch}';
  static String _quartierId() => 'dq_${DateTime.now().microsecondsSinceEpoch}';

  // ── Zones ───────────────────────────────────────────────────────────────
  /// Zones de la boutique, triées par nom (insensible à la casse).
  static List<DeliveryZone> zonesForShop(String shopId) {
    try {
      final list = <DeliveryZone>[];
      for (final raw in _zonesRaw().values) {
        if (raw is! Map) continue;
        if (raw['shop_id']?.toString() != shopId) continue;
        try {
          list.add(DeliveryZone.fromMap(Map<String, dynamic>.from(raw)));
        } catch (_) {}
      }
      list.sort((a, b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return list;
    } catch (e) {
      debugPrint('[Delivery] zonesForShop err: $e');
      return [];
    }
  }

  static Future<DeliveryZone> addZone({
    required String shopId,
    required String name,
  }) async {
    final zone = DeliveryZone(
      id: _zoneId(),
      shopId: shopId,
      name: name.trim(),
      createdAt: DateTime.now(),
    );
    final map = zone.toMap();
    try {
      await _zonesRaw().put(zone.id, map);
    } catch (e) {
      debugPrint('[Delivery] addZone Hive err: $e');
    }
    AppDatabase.bgUpsert('delivery_zones', map);
    AppDatabase.notifyListeners('delivery_zones', shopId);
    return zone;
  }

  /// Supprime une zone. Les quartiers rattachés voient leur `zone_id` remis à
  /// null (côté serveur via FK ON DELETE SET NULL ; côté Hive on le fait ici
  /// pour une cohérence locale immédiate).
  static Future<void> deleteZone(String id, String shopId) async {
    try {
      await _zonesRaw().delete(id);
      // Détacher localement les quartiers de cette zone.
      for (final key in _quartiersRaw().keys.toList()) {
        final raw = _quartiersRaw().get(key);
        if (raw is! Map) continue;
        if (raw['zone_id']?.toString() != id) continue;
        final m = Map<String, dynamic>.from(raw);
        m['zone_id'] = null;
        await _quartiersRaw().put(key, m);
      }
    } catch (e) {
      debugPrint('[Delivery] deleteZone Hive err: $e');
    }
    AppDatabase.bgDelete('delivery_zones', val: id);
    AppDatabase.notifyListeners('delivery_zones', shopId);
    AppDatabase.notifyListeners('delivery_quartiers', shopId);
  }

  // ── Quartiers ───────────────────────────────────────────────────────────
  /// Quartiers de la boutique, filtrables par ville et/ou zone. Triés par nom.
  static List<DeliveryQuartier> quartiersForShop(
    String shopId, {
    String? city,
    String? zoneId,
  }) {
    try {
      final list = <DeliveryQuartier>[];
      for (final raw in _quartiersRaw().values) {
        if (raw is! Map) continue;
        if (raw['shop_id']?.toString() != shopId) continue;
        if (city != null &&
            (raw['city']?.toString().toLowerCase() ?? '') !=
                city.toLowerCase()) {
          continue;
        }
        if (zoneId != null && raw['zone_id']?.toString() != zoneId) continue;
        try {
          list.add(DeliveryQuartier.fromMap(Map<String, dynamic>.from(raw)));
        } catch (_) {}
      }
      list.sort((a, b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return list;
    } catch (e) {
      debugPrint('[Delivery] quartiersForShop err: $e');
      return [];
    }
  }

  /// Villes distinctes configurées (pour l'autocomplete), triées.
  static List<String> citiesForShop(String shopId) {
    final set = <String>{};
    for (final q in quartiersForShop(shopId)) {
      if (q.city.trim().isNotEmpty) set.add(q.city.trim());
    }
    final list = set.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return list;
  }

  static Future<DeliveryQuartier> addQuartier({
    required String shopId,
    required String city,
    required String name,
    required int price,
    String? zoneId,
  }) async {
    final q = DeliveryQuartier(
      id: _quartierId(),
      shopId: shopId,
      zoneId: zoneId,
      city: city.trim(),
      name: name.trim(),
      price: price,
      createdAt: DateTime.now(),
    );
    final map = q.toMap();
    try {
      await _quartiersRaw().put(q.id, map);
    } catch (e) {
      debugPrint('[Delivery] addQuartier Hive err: $e');
    }
    AppDatabase.bgUpsert('delivery_quartiers', map);
    AppDatabase.notifyListeners('delivery_quartiers', shopId);
    return q;
  }

  static Future<void> deleteQuartier(String id, String shopId) async {
    try {
      await _quartiersRaw().delete(id);
    } catch (e) {
      debugPrint('[Delivery] deleteQuartier Hive err: $e');
    }
    AppDatabase.bgDelete('delivery_quartiers', val: id);
    AppDatabase.notifyListeners('delivery_quartiers', shopId);
  }

  /// Renomme une zone existante.
  static Future<void> updateZone(
      String id, String shopId, String name) async {
    final raw = _zonesRaw().get(id);
    if (raw == null) return;
    final z = DeliveryZone.fromMap(Map<String, dynamic>.from(raw))
        .copyWith(name: name.trim());
    final map = z.toMap();
    try {
      await _zonesRaw().put(id, map);
    } catch (e) {
      debugPrint('[Delivery] updateZone Hive err: $e');
    }
    AppDatabase.bgUpsert('delivery_zones', map);
    AppDatabase.notifyListeners('delivery_zones', shopId);
  }

  /// Modifie un quartier existant (ville / nom / prix / zone).
  static Future<void> updateQuartier({
    required String id,
    required String shopId,
    String? city,
    String? name,
    int? price,
    String? zoneId,
    bool clearZone = false,
  }) async {
    final raw = _quartiersRaw().get(id);
    if (raw == null) return;
    final q = DeliveryQuartier.fromMap(Map<String, dynamic>.from(raw)).copyWith(
      city: city?.trim(),
      name: name?.trim(),
      price: price,
      zoneId: zoneId,
      clearZone: clearZone,
    );
    final map = q.toMap();
    try {
      await _quartiersRaw().put(id, map);
    } catch (e) {
      debugPrint('[Delivery] updateQuartier Hive err: $e');
    }
    AppDatabase.bgUpsert('delivery_quartiers', map);
    AppDatabase.notifyListeners('delivery_quartiers', shopId);
  }

  /// Renomme une ville sur TOUS ses quartiers (la ville n'est pas une entité
  /// propre — elle vit sur chaque quartier). No-op si [newCity] vide.
  static Future<void> renameCity(
      String shopId, String oldCity, String newCity) async {
    final nc = newCity.trim();
    if (nc.isEmpty || nc == oldCity) return;
    try {
      for (final key in _quartiersRaw().keys.toList()) {
        final raw = _quartiersRaw().get(key);
        if (raw is! Map) continue;
        if (raw['shop_id']?.toString() != shopId) continue;
        if ((raw['city']?.toString() ?? '') != oldCity) continue;
        final q = DeliveryQuartier.fromMap(Map<String, dynamic>.from(raw))
            .copyWith(city: nc);
        final map = q.toMap();
        await _quartiersRaw().put(q.id, map);
        AppDatabase.bgUpsert('delivery_quartiers', map);
      }
    } catch (e) {
      debugPrint('[Delivery] renameCity err: $e');
    }
    AppDatabase.notifyListeners('delivery_quartiers', shopId);
  }

  /// Ajoute PLUSIEURS quartiers en une fois (même ville + zone). Un seul
  /// `notifyListeners` à la fin. Ids uniques garantis (suffixe d'index).
  static Future<List<DeliveryQuartier>> addQuartiersBatch({
    required String shopId,
    required String city,
    String? zoneId,
    required List<({String name, int price})> items,
  }) async {
    final base = DateTime.now().microsecondsSinceEpoch;
    final created = <DeliveryQuartier>[];
    for (var i = 0; i < items.length; i++) {
      final q = DeliveryQuartier(
        id: 'dq_${base}_$i',
        shopId: shopId,
        zoneId: zoneId,
        city: city.trim(),
        name: items[i].name.trim(),
        price: items[i].price,
        createdAt: DateTime.now(),
      );
      final map = q.toMap();
      try {
        await _quartiersRaw().put(q.id, map);
      } catch (e) {
        debugPrint('[Delivery] addQuartiersBatch Hive err: $e');
      }
      AppDatabase.bgUpsert('delivery_quartiers', map);
      created.add(q);
    }
    AppDatabase.notifyListeners('delivery_quartiers', shopId);
    return created;
  }
}
