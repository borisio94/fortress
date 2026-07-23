import '../../../../core/storage/schema_migrator.dart';

/// Zone de livraison : regroupement nommé de quartiers (ex. « Centre-ville »,
/// « Banlieue »). Sert à filtrer/organiser les quartiers dans le sélecteur de
/// livraison. Une zone appartient à une boutique.
class DeliveryZone {
  final String id;
  final String shopId;
  final String name;
  final DateTime createdAt;

  const DeliveryZone({
    required this.id,
    required this.shopId,
    required this.name,
    required this.createdAt,
  });

  DeliveryZone copyWith({String? name}) => DeliveryZone(
        id: id,
        shopId: shopId,
        name: name ?? this.name,
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
        'name': name,
        'created_at': createdAt.toUtc().toIso8601String(),
      };

  factory DeliveryZone.fromMap(Map<String, dynamic> rawM) {
    final m = _migrator.migrate(rawM);
    return DeliveryZone(
      id: m['id'] as String,
      shopId: m['shop_id'] as String,
      name: (m['name'] ?? '') as String,
      createdAt: m['created_at'] == null
          ? DateTime.now()
          : DateTime.parse(m['created_at'] as String).toLocal(),
    );
  }
}
