import '../../../../core/storage/schema_migrator.dart';

/// Article sans transformation (module finances — PR-B) : boisson, emballage,
/// article vendu tel quel. Stock connu + seuil minimal + coût + prix de vente.
///
/// Rattachable à une [RestaurantActivity] (mode `stock`) via [activityId]
/// (référence logique, pas de FK — cf. hotfix_140).
class StockItem {
  final String id;
  final String shopId;
  final String name;
  final String unit;

  /// Quantité en stock (dans [unit]).
  final double quantity;

  /// Seuil minimal : alerte si `quantity <= minQuantity`.
  final double minQuantity;

  /// Coût d'achat unitaire (FCFA entier).
  final int costPerUnit;

  /// Prix de vente unitaire (FCFA entier).
  final int sellingPrice;

  /// Activité de rattachement (null = article boutique général).
  final String? activityId;

  final DateTime createdAt;

  const StockItem({
    required this.id,
    required this.shopId,
    required this.name,
    required this.unit,
    required this.createdAt,
    this.quantity = 0,
    this.minQuantity = 0,
    this.costPerUnit = 0,
    this.sellingPrice = 0,
    this.activityId,
  });

  /// Stock bas : au niveau ou sous le seuil minimal.
  bool get isLowStock => quantity <= minQuantity;

  StockItem copyWith({
    String? name,
    String? unit,
    double? quantity,
    double? minQuantity,
    int? costPerUnit,
    int? sellingPrice,
    String? activityId,
    bool clearActivity = false,
  }) =>
      StockItem(
        id: id,
        shopId: shopId,
        createdAt: createdAt,
        name: name ?? this.name,
        unit: unit ?? this.unit,
        quantity: quantity ?? this.quantity,
        minQuantity: minQuantity ?? this.minQuantity,
        costPerUnit: costPerUnit ?? this.costPerUnit,
        sellingPrice: sellingPrice ?? this.sellingPrice,
        activityId: clearActivity ? null : (activityId ?? this.activityId),
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
        'unit': unit,
        'quantity': quantity,
        'min_quantity': minQuantity,
        'cost_per_unit': costPerUnit,
        'selling_price': sellingPrice,
        'activity_id': activityId,
        'created_at': createdAt.toUtc().toIso8601String(),
      };

  factory StockItem.fromMap(Map<String, dynamic> rawM) {
    final m = _migrator.migrate(rawM);
    return StockItem(
      id: m['id'].toString(),
      shopId: m['shop_id'].toString(),
      name: (m['name'] ?? '').toString(),
      unit: (m['unit'] ?? 'pièce').toString(),
      quantity: (m['quantity'] as num?)?.toDouble() ?? 0,
      minQuantity: (m['min_quantity'] as num?)?.toDouble() ?? 0,
      costPerUnit: (m['cost_per_unit'] as num?)?.toInt() ?? 0,
      sellingPrice: (m['selling_price'] as num?)?.toInt() ?? 0,
      activityId: m['activity_id']?.toString(),
      createdAt: m['created_at'] == null
          ? DateTime.now()
          : (DateTime.tryParse(m['created_at'].toString())?.toLocal() ??
              DateTime.now()),
    );
  }
}
