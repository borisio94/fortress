import '../../../../core/storage/schema_migrator.dart';

/// Catégories de dépense quotidienne — alignées sur le CHECK SQL de
/// `daily_expenses.category` (hotfix_149).
///
/// Du Dart pur : l'icône de chaque catégorie vit en présentation
/// (`expense_kind_visuals.dart`).
enum ExpenseKind {
  achatMarche('achat_marche', 'Achat marché'),
  electricite('electricite', 'Électricité'),
  gaz('gaz', 'Gaz'),
  eau('eau', 'Eau'),
  transport('transport', 'Transport'),
  entretien('entretien', 'Entretien'),
  personnel('personnel', 'Extras personnel'),
  consigneRendue('consigne_rendue', 'Consigne rendue'),
  autre('autre', 'Autre');

  const ExpenseKind(this.key, this.label);

  final String key;
  final String label;

  /// L'achat de matières premières EST le food cost réel : c'est la seule
  /// catégorie comparable au coût matières théorique des fiches recettes.
  bool get isFoodCost => this == ExpenseKind.achatMarche;

  /// Vraie charge d'exploitation ?
  ///
  /// Le remboursement d'une consigne n'en est PAS une : le client récupère
  /// l'argent qu'il avait lui-même versé. Cette ligne sort bien du tiroir (elle
  /// compte donc pour la clôture de caisse) mais la compter en dépense
  /// amputerait le bénéfice d'une somme qui n'a jamais appartenu au restaurant.
  bool get isCharge => this != ExpenseKind.consigneRendue;

  /// Catégories proposées à la saisie manuelle. `consigne_rendue` en est
  /// exclue : elle est écrite automatiquement au retour des emballages, la
  /// saisir à la main créerait un doublon de sortie de caisse.
  static List<ExpenseKind> get selectable =>
      ExpenseKind.values.where((k) => k != ExpenseKind.consigneRendue).toList();

  static ExpenseKind fromKey(String? k) {
    final v = (k ?? '').trim().toLowerCase();
    for (final e in ExpenseKind.values) {
      if (e.key == v) return e;
    }
    return ExpenseKind.autre;
  }
}

/// Une dépense du jour (Lot E — hotfix_149).
///
/// Distincte d'une charge fixe : celle-ci est un FAIT (« 12 000 F de poisson ce
/// matin »), pas une échéance qu'on anticipe.
class DailyExpense {
  final String id;
  final String shopId;
  final String description;
  final int amount;

  /// Clé de catégorie (cf. [ExpenseKind]).
  final String category;

  /// Qui a payé : au restaurant, l'argent du marché part souvent de la poche
  /// d'un employé qu'il faut rembourser.
  final String? paidBy;

  /// Payé en espèces ? Décide si la dépense sort du TIROIR, et donc si elle
  /// est déduite du total attendu à la clôture de caisse.
  final bool isCash;

  /// INGRÉDIENT ACHETÉ par cette dépense (`ingredients.id`), `null` si la
  /// dépense n'en concerne aucun en particulier.
  ///
  /// C'est ce lien qui rend le coût par plat calculable sans jamais peser quoi
  /// que ce soit : on sait ce que le poulet a coûté sur le mois, et on le
  /// répartit entre les plats qui en contiennent (cf.
  /// `IngredientAllocationService`). Référence logique, sans FK — un
  /// ingrédient supprimé laisse un id orphelin, traité comme « non rattaché ».
  final String? ingredientId;

  final DateTime expenseDate;
  final DateTime createdAt;

  const DailyExpense({
    required this.id,
    required this.shopId,
    required this.description,
    required this.expenseDate,
    required this.createdAt,
    this.amount = 0,
    this.category = 'autre',
    this.paidBy,
    this.isCash = true,
    this.ingredientId,
  });

  ExpenseKind get kind => ExpenseKind.fromKey(category);

  bool get isFoodCost => kind.isFoodCost;

  /// Charge d'exploitation réelle (cf. [ExpenseKind.isCharge]).
  bool get isCharge => kind.isCharge;

  /// Clé `yyyy-MM-dd` d'une date (stockage DATE sans heure).
  static String dayKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  DailyExpense copyWith({
    String? description,
    int? amount,
    String? category,
    String? paidBy,
    bool? isCash,
    DateTime? expenseDate,
    String? ingredientId,

    /// Détache la dépense de son ingrédient (`null` seul voudrait dire
    /// « inchangé », comme pour tous les autres champs).
    bool clearIngredient = false,
  }) =>
      DailyExpense(
        id: id,
        shopId: shopId,
        createdAt: createdAt,
        description: description ?? this.description,
        amount: amount ?? this.amount,
        category: category ?? this.category,
        paidBy: paidBy ?? this.paidBy,
        isCash: isCash ?? this.isCash,
        expenseDate: expenseDate ?? this.expenseDate,
        ingredientId:
            clearIngredient ? null : (ingredientId ?? this.ingredientId),
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
        'paid_by': paidBy,
        'is_cash': isCash,
        'ingredient_id': ingredientId,
        'expense_date': dayKey(expenseDate),
        'created_at': createdAt.toUtc().toIso8601String(),
      };

  factory DailyExpense.fromMap(Map<String, dynamic> rawM) {
    final m = _migrator.migrate(rawM);
    return DailyExpense(
      id: m['id'].toString(),
      shopId: m['shop_id'].toString(),
      description: (m['description'] ?? '').toString(),
      amount: (m['amount'] as num?)?.toInt() ?? 0,
      // Normalisé via l'enum : une valeur hors CHECK ferait rejeter l'upsert
      // par Postgres et l'op serait droppée après dix essais, sans bruit.
      category: ExpenseKind.fromKey(m['category']?.toString()).key,
      paidBy: _nullIfEmpty(m['paid_by']),
      isCash: m['is_cash'] as bool? ?? true,
      ingredientId: _nullIfEmpty(m['ingredient_id']),
      expenseDate:
          DateTime.tryParse(m['expense_date']?.toString() ?? '') ??
              DateTime.now(),
      createdAt: m['created_at'] == null
          ? DateTime.now()
          : (DateTime.tryParse(m['created_at'].toString())?.toLocal() ??
              DateTime.now()),
    );
  }

  static String? _nullIfEmpty(dynamic v) {
    final s = v?.toString().trim() ?? '';
    return s.isEmpty ? null : s;
  }
}
