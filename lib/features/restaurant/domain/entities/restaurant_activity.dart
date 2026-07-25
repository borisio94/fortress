import '../../../../core/storage/schema_migrator.dart';

/// Activité connexe d'un restaurant (module finances — PR-B) :
/// Chawarma · Glace · Bar · Pâtisserie… Permet de segmenter la carte et,
/// plus tard, les ventes/bénéfices par secteur (PR-E).
///
/// Deux modes :
///   * `stock`  : articles vendus tels quels (stock connu + seuil minimal,
///     pas de fiche recette) → voir [StockItem].
///   * `recipe` : plats cuisinés (fiche recette + décrément ingrédients).
class RestaurantActivity {
  final String id;
  final String shopId;
  final String name;

  /// 'stock' ou 'recipe'.
  final String mode;

  /// Suivi de stock actif (mode `stock`).
  final bool trackStock;

  /// Seuil d'alerte global de l'activité (mode `stock`).
  final int stockThreshold;

  final DateTime createdAt;

  const RestaurantActivity({
    required this.id,
    required this.shopId,
    required this.name,
    required this.createdAt,
    this.mode = 'stock',
    this.trackStock = true,
    this.stockThreshold = 0,
  });

  bool get isStockMode => mode == 'stock';
  bool get isRecipeMode => mode == 'recipe';

  RestaurantActivity copyWith({
    String? name,
    String? mode,
    bool? trackStock,
    int? stockThreshold,
  }) =>
      RestaurantActivity(
        id: id,
        shopId: shopId,
        createdAt: createdAt,
        name: name ?? this.name,
        mode: mode ?? this.mode,
        trackStock: trackStock ?? this.trackStock,
        stockThreshold: stockThreshold ?? this.stockThreshold,
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
        'name': name,
        'mode': mode,
        'track_stock': trackStock,
        'stock_threshold': stockThreshold,
        'created_at': createdAt.toUtc().toIso8601String(),
      };

  factory RestaurantActivity.fromMap(Map<String, dynamic> rawM) {
    final m = _migrator.migrate(rawM);
    return RestaurantActivity(
      id: m['id'].toString(),
      shopId: m['shop_id'].toString(),
      name: (m['name'] ?? '').toString(),
      mode: (m['mode'] ?? 'stock').toString(),
      trackStock: m['track_stock'] as bool? ?? true,
      stockThreshold: (m['stock_threshold'] as num?)?.toInt() ?? 0,
      createdAt: m['created_at'] == null
          ? DateTime.now()
          : (DateTime.tryParse(m['created_at'].toString())?.toLocal() ??
              DateTime.now()),
    );
  }
}
