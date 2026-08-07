import '../../../../core/storage/schema_migrator.dart';

/// LE PLAT [productId] CONTIENT L'INGRÉDIENT [ingredientId] — rien de plus.
///
/// Aucune quantité n'est demandée : personne ne pèse 125 g de poulet en plein
/// service. Le coût d'un ingrédient est réparti a posteriori entre les plats
/// qui le portent, au prorata de ce qui s'est vendu sur la période (cf.
/// `IngredientAllocationService`). Cette ligne n'est donc qu'un LIEN.
///
/// [portionWeight] pondère ce lien quand une portion est notoirement plus
/// généreuse qu'une autre — c'est un choix (« grande part »), pas une pesée.
///
/// Pas de FK en base (cf. hotfix_140) : `productId`/`ingredientId` sont des
/// références logiques, l'intégrité est tenue côté application.
class RecipeIngredient {
  final String id;
  final String shopId;
  final String productId;
  final String ingredientId;

  /// GÉNÉROSITÉ de la portion, relative à une part normale :
  /// `0.5` petite · `1` normale (défaut) · `1.5` grande.
  ///
  /// Deux plats de poids 1 et 1,5 se partagent l'ingrédient dans ce rapport,
  /// à volume de ventes égal.
  final double portionWeight;

  /// Quantité de cet ingrédient dans UNE portion du plat, exprimée en [unit].
  ///
  /// Utilisée par la méthode **fiche technique** uniquement — la répartition au
  /// prorata l'ignore complètement. `0` = non renseignée.
  final double quantity;

  /// Unité de la quantité. DOIT être celle de l'ingrédient : le module ne
  /// convertit pas les unités, et un ingrédient déclaré au kilo dosé en
  /// grammes produirait un coût faux d'un facteur mille — faux et crédible,
  /// le pire des deux. Le formulaire l'impose et l'affiche en dur.
  final String unit;

  /// La quantité a-t-elle été saisie DEPUIS le retour de la fiche technique ?
  ///
  /// Des quantités ont été saisies avant l'abandon de la méthode, puis
  /// laissées sans relecture pendant que plus rien ne les utilisait. Les
  /// réactiver telles quelles produirait des coûts théoriques faux et
  /// plausibles. Elles sont donc conservées — c'est une saisie de
  /// l'utilisateur — mais traitées comme des SUGGESTIONS : pré-remplies dans
  /// le formulaire, elles ne comptent dans aucun calcul tant que quelqu'un ne
  /// les a pas confirmées.
  ///
  /// `false` pour toute ligne antérieure (cf. migration de schéma v2).
  final bool quantityConfirmed;

  final DateTime createdAt;

  const RecipeIngredient({
    required this.id,
    required this.shopId,
    required this.productId,
    required this.ingredientId,
    required this.createdAt,
    this.portionWeight = normalPortion,
    this.quantity = 0,
    this.unit = '',
    this.quantityConfirmed = false,
  });

  /// Cette ligne est-elle exploitable par la fiche technique ?
  ///
  /// Les trois conditions ensemble : une quantité positive, une unité, et une
  /// confirmation. Il en manque une → le plat entier sort du calcul théorique
  /// plutôt que d'être chiffré sur une fiche trouée.
  bool get isPriceable =>
      quantityConfirmed && quantity > 0 && quantity.isFinite && unit.isNotEmpty;

  /// Part normale — le défaut, et le cas de l'écrasante majorité des liens.
  static const double normalPortion = 1.0;

  /// Les trois générosités proposées à l'écran. Un champ libre ferait saisir
  /// des décimales qui n'ont aucun sens pour une portion.
  static const double smallPortion = 0.5;
  static const double largePortion = 1.5;

  /// Poids assaini : un négatif ou un non-fini rendrait une part de coût
  /// négative et gonflerait la marge du plat.
  double get effectiveWeight =>
      portionWeight.isFinite && portionWeight > 0 ? portionWeight : 0;

  RecipeIngredient copyWith({
    double? portionWeight,
    double? quantity,
    String? unit,
    bool? quantityConfirmed,
  }) =>
      RecipeIngredient(
        id: id,
        shopId: shopId,
        productId: productId,
        ingredientId: ingredientId,
        createdAt: createdAt,
        portionWeight: portionWeight ?? this.portionWeight,
        quantity: quantity ?? this.quantity,
        unit: unit ?? this.unit,
        quantityConfirmed: quantityConfirmed ?? this.quantityConfirmed,
      );

  static const int currentSchemaVersion = 2;
  static const SchemaMigrator _migrator = SchemaMigrator(
    currentVersion: currentSchemaVersion,
    steps: {
      // v2 — retour de la fiche technique. Toute quantité écrite AVANT cette
      // version date de la période où plus rien ne la lisait : elle n'a pas
      // été relue depuis, on ne peut pas la chiffrer sans confirmation. Pure
      // et idempotente : elle ne fait que poser un drapeau à faux.
      2: _markLegacyQuantityUnconfirmed,
    },
  );

  static Map<String, dynamic> _markLegacyQuantityUnconfirmed(
          Map<String, dynamic> m) =>
      {...m, 'quantity_confirmed': false};

  Map<String, dynamic> toMap() => {
        'schema_version': currentSchemaVersion,
        'id': id,
        'shop_id': shopId,
        'product_id': productId,
        'ingredient_id': ingredientId,
        'portion_weight': portionWeight,
        'quantity': quantity,
        'unit': unit,
        'quantity_confirmed': quantityConfirmed,
        'created_at': createdAt.toUtc().toIso8601String(),
      };

  factory RecipeIngredient.fromMap(Map<String, dynamic> rawM) {
    final m = _migrator.migrate(rawM);
    return RecipeIngredient(
      id: m['id'].toString(),
      shopId: m['shop_id'].toString(),
      productId: m['product_id'].toString(),
      ingredientId: m['ingredient_id'].toString(),
      // Absent des liens antérieurs à la répartition au prorata : portion
      // normale. Une fiche déjà saisie garde donc exactement le poids qu'elle
      // aurait eu si elle avait été créée aujourd'hui.
      portionWeight:
          (m['portion_weight'] as num?)?.toDouble() ?? normalPortion,
      quantity: (m['quantity'] as num?)?.toDouble() ?? 0,
      unit: (m['unit'] ?? '').toString(),
      quantityConfirmed: m['quantity_confirmed'] == true,
      createdAt: m['created_at'] == null
          ? DateTime.now()
          : (DateTime.tryParse(m['created_at'].toString())?.toLocal() ??
              DateTime.now()),
    );
  }
}
