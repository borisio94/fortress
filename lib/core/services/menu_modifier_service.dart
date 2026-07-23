import 'package:flutter/foundation.dart' show debugPrint;
import 'package:hive_flutter/hive_flutter.dart';

import '../../features/restaurant/domain/entities/menu_modifier.dart';
import '../database/app_database.dart';
import '../storage/hive_boxes.dart';

/// Service Hive-first des groupes de modificateurs de menu (cuisson,
/// options, suppléments).
///
/// Même triptyque que [RestaurantTableService] et `DeliveryZoneService` :
/// écriture Hive immédiate → push Supabase en arrière-plan → notification
/// des listeners. Ids générés côté client (`mm_` + microsecondes) pour que
/// la configuration soit utilisable hors ligne.
class MenuModifierService {
  MenuModifierService._();

  static Box<Map> _raw() => HiveBoxes.menuModifiersBox;

  static String _id() => 'mm_${DateTime.now().microsecondsSinceEpoch}';

  /// Tous les groupes de la boutique, triés par nom.
  static List<MenuModifier> forShop(String shopId) {
    try {
      final list = <MenuModifier>[];
      for (final raw in _raw().values) {
        if (raw['shop_id']?.toString() != shopId) continue;
        try {
          list.add(MenuModifier.fromMap(Map<String, dynamic>.from(raw)));
        } catch (_) {/* ligne corrompue : ignorée plutôt que page cassée */}
      }
      list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return list;
    } catch (e) {
      debugPrint('[MenuModifier] forShop err: $e');
      return [];
    }
  }

  /// Crée un groupe. [productIds] vide = groupe applicable à TOUTE la carte.
  ///
  /// Un groupe lié à plusieurs produits est stocké comme autant de lignes
  /// que de produits : la table porte un seul `product_id`, et dupliquer la
  /// ligne évite d'introduire une table de liaison pour une fonctionnalité
  /// de cette taille. Les lignes partagent leur `name`, ce qui suffit à les
  /// regrouper à l'affichage.
  static Future<void> addGroup({
    required String shopId,
    required String name,
    required List<ModifierOption> options,
    List<String> productIds = const [],
  }) async {
    if (productIds.isEmpty) {
      await _put(MenuModifier(
        id: _id(),
        shopId: shopId,
        name: name.trim(),
        options: options,
        createdAt: DateTime.now(),
      ));
      return;
    }
    for (final pid in productIds) {
      await _put(MenuModifier(
        id: _id(),
        shopId: shopId,
        productId: pid,
        name: name.trim(),
        options: options,
        createdAt: DateTime.now(),
      ));
      // Ids dérivés des microsecondes : deux créations dans la même
      // microseconde produiraient la même clé et la seconde écraserait la
      // première. Une micro-pause garantit l'unicité.
      await Future<void>.delayed(const Duration(microseconds: 2));
    }
  }

  static Future<void> update(MenuModifier modifier) => _put(modifier);

  static Future<void> _put(MenuModifier m) async {
    final map = m.toMap();
    try {
      await _raw().put(m.id, map);
    } catch (e) {
      debugPrint('[MenuModifier] put Hive err: $e');
    }
    AppDatabase.bgUpsert('menu_modifiers', map);
    AppDatabase.notifyListeners('menu_modifiers', m.shopId);
  }

  static Future<void> delete(String id, String shopId) async {
    try {
      await _raw().delete(id);
    } catch (e) {
      debugPrint('[MenuModifier] delete Hive err: $e');
    }
    AppDatabase.bgDelete('menu_modifiers', val: id);
    AppDatabase.notifyListeners('menu_modifiers', shopId);
  }

  /// Supprime toutes les lignes portant ce nom de groupe (toutes ses
  /// liaisons produit d'un coup) — c'est l'unité de suppression attendue
  /// par l'utilisateur, qui a créé « Cuisson » et non N lignes.
  static Future<void> deleteGroupByName(String shopId, String name) async {
    for (final m in forShop(shopId)) {
      if (m.name == name) await delete(m.id, shopId);
    }
  }
}
