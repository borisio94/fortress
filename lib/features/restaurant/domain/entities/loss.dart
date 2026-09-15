import '../../../../core/storage/schema_migrator.dart';

/// Assiettes d'un plat perdues (hotfix_179) : plat raté, tournée annulée,
/// addition impayée dont la tournée était partie en cuisine.
class WastedPlate {
  final String productId;
  final double quantity;

  const WastedPlate({required this.productId, required this.quantity});

  Map<String, dynamic> toMap() =>
      {'product_id': productId, 'quantity': quantity};

  /// `null` si la ligne est inexploitable (plat absent, quantité nulle).
  static WastedPlate? fromRaw(dynamic raw) {
    if (raw is! Map) return null;
    final pid = raw['product_id']?.toString() ?? '';
    final qty = (raw['quantity'] as num?)?.toDouble() ?? 0;
    if (pid.isEmpty || qty <= 0 || !qty.isFinite) return null;
    return WastedPlate(productId: pid, quantity: qty);
  }
}

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

  /// ASSIETTES PERDUES (hotfix_179). Le bilan les compte comme des parts dans
  /// la répartition du coût matières : leur matière est RETIRÉE de ce que
  /// portent les plats vendus, au lieu de s'y ajouter une seconde fois.
  final List<WastedPlate> items;

  /// INGRÉDIENT MANQUANT à l'inventaire (hotfix_179). Le montant est retiré
  /// des achats de cet ingrédient sur la période, plafonné à ces achats.
  final String? ingredientId;

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
    this.items = const [],
    this.ingredientId,
  });

  /// Perte de MATIÈRE — rattachée à des assiettes ou à un ingrédient.
  ///
  /// C'est le rattachement, et non la catégorie, qui décide du calcul : seule
  /// une perte rattachée peut être retirée de l'assiette. Une perte non
  /// rattachée reste une charge ordinaire, comptée à son montant saisi.
  ///
  /// Un `ingredient_id` qui n'est pas un ingrédient (`si_…`, une fourniture)
  /// ne rattache pas : les fournitures ne sont pas réparties sur les plats.
  bool get isMaterial =>
      items.isNotEmpty || (ingredientId?.startsWith('ig_') ?? false);

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
        // Rattachement conservé : modifier la description d'une perte ne doit
        // pas la faire basculer de matière en charge.
        items: items,
        ingredientId: ingredientId,
      );

  // v2 (hotfix_179) : `items` + `ingredient_id`. Aucune transformation — une
  // perte v1 n'était rattachée à rien, ce que les défauts disent déjà.
  static const int currentSchemaVersion = 2;
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
        'items': [for (final p in items) p.toMap()],
        'ingredient_id': ingredientId,
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
      items: [
        for (final raw in (m['items'] as List? ?? const []))
          if (WastedPlate.fromRaw(raw) case final p?) p,
      ],
      ingredientId: () {
        final s = m['ingredient_id']?.toString().trim() ?? '';
        return s.isEmpty ? null : s;
      }(),
      createdAt: m['created_at'] == null
          ? DateTime.now()
          : (DateTime.tryParse(m['created_at'].toString())?.toLocal() ??
              DateTime.now()),
    );
  }
}
