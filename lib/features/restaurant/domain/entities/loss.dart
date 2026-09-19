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

/// Perte refusée : son rattachement ne respecte pas la règle de sa catégorie
/// (cf. [Loss.attachmentError]).
class LossAttachmentException implements Exception {
  final String message;
  const LossAttachmentException(this.message);

  @override
  String toString() => message;
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

  // ── Matière ou charge (audit des marges, 2026-09-15) ───────────────────

  /// Catégories qui désignent de la MATIÈRE : rattachement OBLIGATOIRE, à des
  /// assiettes ou à un ingrédient. Sans lui, la perte ne peut pas être
  /// retirée de l'assiette à répartir et la matière serait comptée deux fois.
  ///
  /// `ecart_inventaire` y figure mais accepte aussi une FOURNITURE (`si_…`) :
  /// il reste alors une charge.
  static const Set<String> materialCategories = {
    'reste_invendu',
    'plat_mal_fait',
    'non_paye',
    'ecart_inventaire',
  };

  /// Catégories qui ne sont PAS de la matière : aucun rattachement, hors du
  /// retrait de l'assiette. Une charge, comptée à son montant.
  static const Set<String> chargeCategories = {
    'casse',
    'materiel_endommage',
    'consigne_perdue',
  };

  static bool _isIngredientId(String? id) => id?.startsWith('ig_') ?? false;
  static bool _isSupplyId(String? id) => id?.startsWith('si_') ?? false;

  /// LA RÈGLE DE RATTACHEMENT, sous forme pure. `null` = conforme, sinon le
  /// motif du refus, affichable tel quel.
  ///
  ///   * matière (`reste_invendu`, `plat_mal_fait`, `non_paye`) : des
  ///     assiettes ou un ingrédient, obligatoirement ;
  ///   * `ecart_inventaire` : un ingrédient, des assiettes, ou une fourniture ;
  ///   * charge (`casse`, `materiel_endommage`, `consigne_perdue`) : rien ;
  ///   * `autre` : optionnel — assiettes ou ingrédient.
  static String? attachmentError({
    required String category,
    required List<WastedPlate> items,
    required String? ingredientId,
  }) {
    final hasPlates = items.isNotEmpty;
    final hasIngredient = _isIngredientId(ingredientId);
    final hasSupply = _isSupplyId(ingredientId);
    final attached = hasPlates || hasIngredient || hasSupply;

    if (chargeCategories.contains(category)) {
      return attached
          ? 'Cette catégorie est une charge : elle ne se rattache ni à des '
              'plats ni à un ingrédient.'
          : null;
    }
    if (category == 'ecart_inventaire') {
      return attached
          ? null
          : 'Un écart d\'inventaire doit désigner l\'ingrédient ou la '
              'fourniture manquante.';
    }
    if (hasSupply) {
      return 'Une fourniture ne se rattache qu\'à un écart d\'inventaire.';
    }
    if (materialCategories.contains(category) && !hasPlates && !hasIngredient) {
      return 'Perte de matière : indiquez les plats perdus ou l\'ingrédient '
          'concerné.';
    }
    return null;
  }

  /// Motif de refus de CETTE perte, `null` si elle est conforme.
  String? get attachmentIssue => attachmentError(
      category: category, items: items, ingredientId: ingredientId);

  /// Perte de MATIÈRE — retirée de l'assiette à répartir par le bilan.
  ///
  /// Il faut les DEUX : une catégorie qui peut être de la matière (toute sauf
  /// les charges) ET un rattachement à des assiettes ou à un ingrédient. Une
  /// fourniture (`si_…`) ne rend jamais matière : les fournitures ne sont pas
  /// réparties sur les plats. Une catégorie de charge reste une charge même
  /// si une donnée hors règle lui porte des assiettes (synchro, ancienne
  /// version) — elle est alors comptée à son montant.
  bool get isMaterial =>
      !chargeCategories.contains(category) &&
      (items.isNotEmpty || _isIngredientId(ingredientId));

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
    List<WastedPlate>? items,
    String? ingredientId,

    /// Détache l'ingrédient (`null` seul voudrait dire « inchangé »).
    bool clearIngredient = false,
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
        // Rattachement conservé par défaut : modifier la description d'une
        // perte ne doit pas la faire basculer de matière en charge.
        items: items ?? this.items,
        ingredientId:
            clearIngredient ? null : (ingredientId ?? this.ingredientId),
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
