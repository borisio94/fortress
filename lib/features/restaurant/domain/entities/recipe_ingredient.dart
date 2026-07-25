import '../../../../core/storage/schema_migrator.dart';

/// Une ligne de fiche recette : le plat [productId] utilise [quantity] [unit]
/// de l'ingrédient [ingredientId] (module finances — PR-A).
///
/// Pas de FK en base (cf. hotfix_140) : `productId`/`ingredientId` sont des
/// références logiques, l'intégrité est tenue côté application.
class RecipeIngredient {
  final String id;
  final String shopId;
  final String productId;
  final String ingredientId;

  /// Quantité d'ingrédient utilisée pour UNE unité de plat (dans [unit]).
  final double quantity;

  /// Unité de la quantité (idéalement celle de l'ingrédient).
  final String unit;

  final DateTime createdAt;

  const RecipeIngredient({
    required this.id,
    required this.shopId,
    required this.productId,
    required this.ingredientId,
    required this.quantity,
    required this.unit,
    required this.createdAt,
  });

  RecipeIngredient copyWith({double? quantity, String? unit}) =>
      RecipeIngredient(
        id: id,
        shopId: shopId,
        productId: productId,
        ingredientId: ingredientId,
        createdAt: createdAt,
        quantity: quantity ?? this.quantity,
        unit: unit ?? this.unit,
      );

  static const int currentSchemaVersion = 1;
  static const SchemaMigrator _migrator = SchemaMigrator(
    currentVersion: currentSchemaVersion,
    steps: {},
  );

  Map<String, dynamic> toMap() => {
        'schema_version': currentSchemaVersion,
        'id': id,
        'shop_id': shopId,
        'product_id': productId,
        'ingredient_id': ingredientId,
        'quantity': quantity,
        'unit': unit,
        'created_at': createdAt.toUtc().toIso8601String(),
      };

  factory RecipeIngredient.fromMap(Map<String, dynamic> rawM) {
    final m = _migrator.migrate(rawM);
    return RecipeIngredient(
      id: m['id'].toString(),
      shopId: m['shop_id'].toString(),
      productId: m['product_id'].toString(),
      ingredientId: m['ingredient_id'].toString(),
      quantity: (m['quantity'] as num?)?.toDouble() ?? 0,
      unit: (m['unit'] ?? '').toString(),
      createdAt: m['created_at'] == null
          ? DateTime.now()
          : (DateTime.tryParse(m['created_at'].toString())?.toLocal() ??
              DateTime.now()),
    );
  }
}
