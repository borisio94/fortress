import '../../../../core/storage/schema_migrator.dart';

/// Quartier de livraison : un tarif de livraison pour un quartier d'une ville
/// donnée. Rattaché optionnellement à une [DeliveryZone] (regroupement).
/// `price` est en FCFA (entier).
class DeliveryQuartier {
  final String id;
  final String shopId;
  final String? zoneId;
  final String city;
  final String name;
  final int price;
  final DateTime createdAt;

  const DeliveryQuartier({
    required this.id,
    required this.shopId,
    this.zoneId,
    required this.city,
    required this.name,
    required this.price,
    required this.createdAt,
  });

  DeliveryQuartier copyWith({
    String? city,
    String? name,
    int? price,
    String? zoneId,
    bool clearZone = false,
  }) =>
      DeliveryQuartier(
        id: id,
        shopId: shopId,
        zoneId: clearZone ? null : (zoneId ?? this.zoneId),
        city: city ?? this.city,
        name: name ?? this.name,
        price: price ?? this.price,
        createdAt: createdAt,
      );

  // Schema versioning — cf. lib/core/storage/schema_migrator.dart.
  static const int currentSchemaVersion = 1;
  static final SchemaMigrator _migrator = SchemaMigrator(
    currentVersion: currentSchemaVersion,
    steps: const {},
  );

  Map<String, dynamic> toMap() => {
        'schema_version': currentSchemaVersion,
        'id': id,
        'shop_id': shopId,
        'zone_id': zoneId,
        'city': city,
        'name': name,
        'price': price,
        'created_at': createdAt.toUtc().toIso8601String(),
      };

  factory DeliveryQuartier.fromMap(Map<String, dynamic> rawM) {
    final m = _migrator.migrate(rawM);
    return DeliveryQuartier(
      id: m['id'] as String,
      shopId: m['shop_id'] as String,
      zoneId: m['zone_id'] as String?,
      city: (m['city'] ?? '') as String,
      name: (m['name'] ?? '') as String,
      price: (m['price'] as num?)?.toInt() ?? 0,
      createdAt: m['created_at'] == null
          ? DateTime.now()
          : DateTime.parse(m['created_at'] as String).toLocal(),
    );
  }
}
