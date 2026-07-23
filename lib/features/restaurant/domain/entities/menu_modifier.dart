import '../../../../core/storage/schema_migrator.dart';

/// Une option à l'intérieur d'un groupe de modificateurs.
///
/// Ex. dans le groupe « Cuisson » : « Saignant » (impact 0), « Bien cuit »
/// (impact 0) ; dans « Suppléments » : « Fromage » (impact +500 F).
class ModifierOption {
  final String name;

  /// Impact sur le prix de la ligne, en unité monétaire entière (FCFA).
  /// Peut être négatif (remise « sans sauce »).
  final int priceImpact;

  const ModifierOption({required this.name, this.priceImpact = 0});

  Map<String, dynamic> toMap() => {
        'name': name,
        'price_impact': priceImpact,
      };

  factory ModifierOption.fromMap(Map<String, dynamic> m) => ModifierOption(
        name: (m['name'] ?? '').toString(),
        priceImpact: (m['price_impact'] as num?)?.toInt() ?? 0,
      );
}

/// Groupe de modificateurs rattaché à un produit (ou à toute la carte quand
/// [productId] est null).
///
/// `options` est stocké en JSONB côté Supabase et en `List<Map>` côté Hive.
/// Le champ `price_impact` de la table porte l'impact PAR DÉFAUT du groupe ;
/// chaque option peut le surcharger — c'est l'option qui fait foi au moment
/// de la prise de commande.
class MenuModifier {
  final String id;
  final String shopId;

  /// Produit auquel le groupe s'applique. `null` = applicable à tous les
  /// produits de la boutique (ex. un groupe « Cuisson » générique).
  final String? productId;
  final String name;
  final List<ModifierOption> options;
  final int priceImpact;
  final DateTime createdAt;

  const MenuModifier({
    required this.id,
    required this.shopId,
    required this.name,
    required this.createdAt,
    this.productId,
    this.options = const [],
    this.priceImpact = 0,
  });

  /// True si le groupe s'applique au produit donné.
  bool appliesTo(String productId) =>
      this.productId == null || this.productId == productId;

  static const int currentSchemaVersion = 1;
  static const SchemaMigrator _migrator = SchemaMigrator(
    currentVersion: currentSchemaVersion,
    steps: {},
  );

  Map<String, dynamic> toMap() => {
        'schema_version': currentSchemaVersion,
        'id': id,
        'shop_id': shopId,
        'product_id': productId,
        'name': name,
        'options': options.map((o) => o.toMap()).toList(),
        'price_impact': priceImpact,
        'created_at': createdAt.toUtc().toIso8601String(),
      };

  factory MenuModifier.fromMap(Map<String, dynamic> rawM) {
    final m = _migrator.migrate(rawM);
    // `options` arrive soit en List<Map> (Hive), soit en List<dynamic> issue
    // du JSONB Supabase — d'où la normalisation défensive.
    final rawOptions = m['options'];
    final options = <ModifierOption>[];
    if (rawOptions is List) {
      for (final o in rawOptions) {
        if (o is Map) {
          options.add(ModifierOption.fromMap(Map<String, dynamic>.from(o)));
        }
      }
    }
    return MenuModifier(
      id: m['id'].toString(),
      shopId: m['shop_id'].toString(),
      productId: m['product_id']?.toString(),
      name: (m['name'] ?? '').toString(),
      options: options,
      priceImpact: (m['price_impact'] as num?)?.toInt() ?? 0,
      createdAt: m['created_at'] == null
          ? DateTime.now()
          : (DateTime.tryParse(m['created_at'].toString())?.toLocal() ??
              DateTime.now()),
    );
  }
}
