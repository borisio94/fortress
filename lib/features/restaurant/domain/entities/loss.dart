import '../../../../core/storage/schema_migrator.dart';

/// Déclaration de perte (module finances — PR-C) : casse, invendu en fin de
/// service, plat mal fait, addition non payée, matériel endommagé…
///
/// [origin] libre indique la provenance (« service midi », « réconciliation:
/// <ingrédient> » pour une perte issue d'un écart d'inventaire, etc.).
class Loss {
  final String id;
  final String shopId;
  final String description;

  /// Montant de la perte (FCFA entier).
  final int amount;

  /// 'casse' · 'reste_invendu' · 'plat_mal_fait' · 'non_paye' ·
  /// 'materiel_endommage' · 'autre'.
  final String category;

  /// Provenance libre de la perte (service, réconciliation, note…).
  final String origin;

  /// Date de la perte (date seule, sans heure).
  final DateTime date;

  /// Qui a déclaré la perte (id/nom, optionnel).
  final String? declaredBy;

  final DateTime createdAt;

  const Loss({
    required this.id,
    required this.shopId,
    required this.description,
    required this.date,
    required this.createdAt,
    this.amount = 0,
    this.category = 'autre',
    this.origin = '',
    this.declaredBy,
  });

  /// Clé `yyyy-MM-dd` d'une date (stockage DATE sans heure).
  static String dayKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  Loss copyWith({
    String? description,
    int? amount,
    String? category,
    String? origin,
    DateTime? date,
    String? declaredBy,
  }) =>
      Loss(
        id: id,
        shopId: shopId,
        createdAt: createdAt,
        description: description ?? this.description,
        amount: amount ?? this.amount,
        category: category ?? this.category,
        origin: origin ?? this.origin,
        date: date ?? this.date,
        declaredBy: declaredBy ?? this.declaredBy,
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
        'description': description,
        'amount': amount,
        'category': category,
        'origin': origin,
        'date': dayKey(date),
        'declared_by': declaredBy,
        'created_at': createdAt.toUtc().toIso8601String(),
      };

  factory Loss.fromMap(Map<String, dynamic> rawM) {
    final m = _migrator.migrate(rawM);
    return Loss(
      id: m['id'].toString(),
      shopId: m['shop_id'].toString(),
      description: (m['description'] ?? '').toString(),
      amount: (m['amount'] as num?)?.toInt() ?? 0,
      category: (m['category'] ?? 'autre').toString(),
      origin: (m['origin'] ?? '').toString(),
      date: m['date'] == null
          ? DateTime.now()
          : (DateTime.tryParse(m['date'].toString()) ?? DateTime.now()),
      declaredBy: m['declared_by']?.toString(),
      createdAt: m['created_at'] == null
          ? DateTime.now()
          : (DateTime.tryParse(m['created_at'].toString())?.toLocal() ??
              DateTime.now()),
    );
  }
}
