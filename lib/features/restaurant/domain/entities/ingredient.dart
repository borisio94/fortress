import '../../../../core/storage/schema_migrator.dart';

/// Un ingrédient du catalogue restaurant (module finances — PR-A).
///
/// Deux types :
///   * `specialized` : lié à un seul plat → coût attribué à 100 % à ce plat.
///   * `shared`      : lié à plusieurs plats → coût réparti à parts égales
///     entre tous les plats qui l'utilisent (le calcul de la part vit dans
///     `RecipeService`, pas ici : l'ingrédient ne « sait » pas combien de
///     plats l'emploient).
class Ingredient {
  final String id;
  final String shopId;
  final String name;

  /// Unité de mesure (« g », « kg », « L », « pièce »…).
  final String unit;

  /// Quantité en stock (exprimée en [unit]).
  final double quantity;

  /// Seuil d'alerte : stock bas dès que `quantity <= alertThreshold`
  /// (0 = pas d'alerte configurée).
  final double alertThreshold;

  /// Coût d'achat unitaire, en FCFA entier (par [unit]).
  final int costPerUnit;

  /// 'specialized' (un seul plat) ou 'shared' (plusieurs plats).
  final String type;

  final DateTime createdAt;

  const Ingredient({
    required this.id,
    required this.shopId,
    required this.name,
    required this.createdAt,
    this.unit = 'pièce',
    this.quantity = 0,
    this.alertThreshold = 0,
    this.costPerUnit = 0,
    this.type = 'specialized',
  });

  bool get isShared => type == 'shared';

  /// Stock bas : un seuil est défini et il est atteint.
  bool get isLowStock => alertThreshold > 0 && quantity <= alertThreshold;

  Ingredient copyWith({
    String? name,
    String? unit,
    double? quantity,
    double? alertThreshold,
    int? costPerUnit,
    String? type,
  }) =>
      Ingredient(
        id: id,
        shopId: shopId,
        createdAt: createdAt,
        name: name ?? this.name,
        unit: unit ?? this.unit,
        quantity: quantity ?? this.quantity,
        alertThreshold: alertThreshold ?? this.alertThreshold,
        costPerUnit: costPerUnit ?? this.costPerUnit,
        type: type ?? this.type,
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
        'alert_threshold': alertThreshold,
        'cost_per_unit': costPerUnit,
        'type': type,
        'created_at': createdAt.toUtc().toIso8601String(),
      };

  factory Ingredient.fromMap(Map<String, dynamic> rawM) {
    final m = _migrator.migrate(rawM);
    return Ingredient(
      id: m['id'].toString(),
      shopId: m['shop_id'].toString(),
      name: (m['name'] ?? '').toString(),
      unit: (m['unit'] ?? 'pièce').toString(),
      quantity: (m['quantity'] as num?)?.toDouble() ?? 0,
      alertThreshold: (m['alert_threshold'] as num?)?.toDouble() ?? 0,
      costPerUnit: (m['cost_per_unit'] as num?)?.toInt() ?? 0,
      type: (m['type'] ?? 'specialized').toString(),
      createdAt: m['created_at'] == null
          ? DateTime.now()
          : (DateTime.tryParse(m['created_at'].toString())?.toLocal() ??
              DateTime.now()),
    );
  }
}
