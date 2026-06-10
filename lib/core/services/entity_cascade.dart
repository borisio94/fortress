// ═════════════════════════════════════════════════════════════════════════════
// Helpers de PROPAGATION (cascade) d'une édition d'entité vers les snapshots
// qui la référencent (lignes de commande, produits…).
//
// Pur Dart (aucun import Flutter / Hive) → testable
// (test/unit/entity_cascade_test.dart).
//
// PRINCIPE : on propage l'IDENTITÉ (nom, image) — sûr et attendu partout.
// Le PRIX des lignes de commande reste FIGÉ (intégrité comptable des ventes
// déjà émises) ; la propagation de prix vivante (panier / commande en cours)
// est gérée ailleurs.
// ═════════════════════════════════════════════════════════════════════════════

class EntityCascade {
  EntityCascade._();

  /// Met à jour, dans la liste `items` d'une commande (map), les snapshots
  /// d'un produit (nom + image) pour toutes les lignes dont `product_id`
  /// correspond. Mute la map en place. Retourne `true` si au moins une ligne
  /// a changé.
  ///
  /// Le PRIX (`unit_price`/`custom_price`) n'est volontairement PAS touché.
  static bool applyProductIdentityToOrder(
    Map<String, dynamic> order, {
    required String productId,
    String? newName,
    String? newImageUrl,
  }) {
    final items = order['items'];
    if (items is! List) return false;
    var changed = false;
    final updated = <dynamic>[];
    for (final raw in items) {
      if (raw is! Map) { updated.add(raw); continue; }
      final im = Map<String, dynamic>.from(raw);
      if (im['product_id'] == productId) {
        if (newName != null && im['product_name'] != newName) {
          im['product_name'] = newName;
          changed = true;
        }
        if (im['image_url'] != newImageUrl) {
          im['image_url'] = newImageUrl;
          changed = true;
        }
      }
      updated.add(im);
    }
    if (changed) order['items'] = updated;
    return changed;
  }

  /// Renomme la valeur d'un champ texte d'une map produit (ex. 'category_id'
  /// = nom de catégorie, 'brand' = nom de marque). Mute en place. Retourne
  /// `true` si modifié.
  static bool renameProductField(
    Map<String, dynamic> product,
    String field,
    String oldValue,
    String newValue,
  ) {
    if (product[field] == oldValue && oldValue != newValue) {
      product[field] = newValue;
      return true;
    }
    return false;
  }
}
