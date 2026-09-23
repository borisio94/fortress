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

  /// MÉTHODE DE CHIFFRAGE DE CET INGRÉDIENT — `'repartition'` ou `'fiche'`.
  ///
  /// Le choix est porté par l'ingrédient et non par la boutique, parce que
  /// deux familles coexistent dans une cuisine et ne se mesurent pas pareil :
  ///
  ///   * le riz, l'huile, la viande s'achètent au kilo et se pèsent dans
  ///     l'assiette → `'fiche'`, seule méthode capable de détecter un
  ///     sur-dosage ;
  ///   * le piment, les cubes, les épices s'achètent en tas → `'repartition'`,
  ///     parce que personne ne pèsera jamais 3 g de piment par assiette.
  ///
  /// Un réglage unique pour toute la boutique imposait le mauvais compromis
  /// dans les deux sens : aucun contrôle sur le poste qui coûte cher, ou une
  /// fiche jamais remplie faute d'une quantité d'épice.
  ///
  /// Défaut `'repartition'` : le parc existant garde son comportement.
  final String costMethod;

  /// Date d'achat (date seule, sans heure) — INFORMATIF (hotfix_142).
  ///
  /// N'entre pas dans le calcul du bénéfice : le coût matières est compté à la
  /// vente, via la fiche recette. `null` = non renseignée.
  final DateTime? purchaseDate;

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
    this.costMethod = costRepartition,
    this.purchaseDate,
  });

  /// Les deux méthodes de chiffrage. Les chaînes sont les valeurs persistées
  /// (`ingredients.cost_method`, contrainte CHECK côté Postgres) : ne pas les
  /// renommer sans migration.
  static const String costRepartition = 'repartition';
  static const String costSheet = 'fiche';

  /// Cet ingrédient est-il chiffré à la fiche technique ?
  ///
  /// Toute valeur inconnue retombe sur la répartition : une donnée abîmée ne
  /// doit pas rendre un plat non chiffrable, elle doit le ramener au
  /// comportement par défaut.
  bool get usesTechnicalSheet => costMethod == costSheet;

  /// Libellé court de la méthode de chiffrage — CELUI DU SÉLECTEUR.
  ///
  /// Il disait « Fiche » et « Répartition » pendant que le sélecteur, lui,
  /// proposait « Quantité connue » et « Sans peser ». Deux vocabulaires pour
  /// le MÊME choix, à deux écrans d'intervalle : le restaurateur cochait
  /// « Quantité connue » et retrouvait « Fiche » dans sa liste.
  ///
  /// Les mots du sélecteur l'emportent, et c'est délibéré : ce sont eux qu'on
  /// lit au moment de DÉCIDER. Une liste peut se relire, une décision se prend
  /// une fois.
  String get costMethodLabel =>
      usesTechnicalSheet ? 'Quantité connue' : 'Sans peser';

  /// Clé `yyyy-MM-dd` d'une date (stockage DATE sans heure).
  static String dayKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

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
    String? costMethod,
    DateTime? purchaseDate,
    /// Efface la date d'achat (un `null` passé à [purchaseDate] signifie
    /// « inchangée », comme pour tous les autres champs).
    bool clearPurchaseDate = false,
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
        costMethod: costMethod ?? this.costMethod,
        purchaseDate: clearPurchaseDate
            ? null
            : (purchaseDate ?? this.purchaseDate),
      );

  static const int currentSchemaVersion = 2;
  static const SchemaMigrator _migrator = SchemaMigrator(
    currentVersion: currentSchemaVersion,
    // v2 — méthode de chiffrage par ingrédient (hotfix_157). Tout l'existant
    // était chiffré à la répartition : on le déclare explicitement plutôt que
    // de s'en remettre au défaut du constructeur, pour que la valeur soit
    // écrite en base au premier réenregistrement. Pure et idempotente.
    steps: {2: _defaultCostMethod},
  );

  static Map<String, dynamic> _defaultCostMethod(Map<String, dynamic> m) =>
      {...m, 'cost_method': m['cost_method'] ?? costRepartition};

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
        'cost_method': costMethod,
        'purchase_date':
            purchaseDate == null ? null : dayKey(purchaseDate!),
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
      // Toute valeur inattendue retombe sur la répartition : une donnée abîmée
      // ne doit pas rendre un plat non chiffrable, elle doit le ramener au
      // comportement par défaut.
      costMethod: m['cost_method'] == costSheet ? costSheet : costRepartition,
      // Absente des ingrédients antérieurs à hotfix_142 → non renseignée.
      purchaseDate: m['purchase_date'] == null ||
              m['purchase_date'].toString().isEmpty
          ? null
          : DateTime.tryParse(m['purchase_date'].toString()),
      createdAt: m['created_at'] == null
          ? DateTime.now()
          : (DateTime.tryParse(m['created_at'].toString())?.toLocal() ??
              DateTime.now()),
    );
  }
}
