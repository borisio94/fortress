import 'package:equatable/equatable.dart';
import '../../../../core/storage/schema_migrator.dart';

/// Template de message WhatsApp utilisé pour transférer une commande à un
/// livreur. Le `body` peut contenir des placeholders `{{nom_variable}}`
/// remplacés au moment du transfert par `delivery_message_builder`.
///
/// Variables supportées : caisse, titre_livraison, reference, client_name,
/// client_phone, lieu_livraison, ville_expedition, produits, date, heure,
/// prix_produit, frais_livraison, total, notes, partner_name, partner_phone,
/// partner_city, partner_notes.
///
/// Portée (hotfix_093) :
///   • `partnerId == null` → template SHOP-WIDE (rétro-compatible avec
///     l'existant) : sert de défaut quand aucun partenaire n'a son propre
///     template.
///   • `partnerId != null` → template SPÉCIFIQUE à un partenaire (FK vers
///     stock_locations). Priorité sur le shop-wide quand on transfère
///     à ce partenaire.
///
/// Persistence :
///   • SQL  : table `delivery_templates` (cf. hotfix_049 + hotfix_093).
///   • Hive : `HiveBoxes.deliveryTemplatesBox` (cache offline, synchronisé
///            via Supabase Realtime).
class DeliveryTemplate extends Equatable {
  final String   id;
  final String   shopId;
  /// Null = template shop-wide. Sinon, id du partenaire (StockLocation)
  /// auquel ce template appartient en propre. Voir hotfix_093.
  final String?  partnerId;
  final String   name;
  final String   body;
  /// Un seul template par (shop, partenaire) peut avoir `isDefault=true`
  /// (index unique partial côté SQL). Utilisé en fallback quand aucune
  /// attribution explicite n'existe pour le destinataire.
  final bool     isDefault;
  final DateTime createdAt;
  final DateTime updatedAt;

  const DeliveryTemplate({
    required this.id,
    required this.shopId,
    this.partnerId,
    required this.name,
    required this.body,
    this.isDefault = false,
    required this.createdAt,
    required this.updatedAt,
  });

  DeliveryTemplate copyWith({
    String?   id,
    String?   shopId,
    String?   partnerId,
    bool      clearPartnerId = false,
    String?   name,
    String?   body,
    bool?     isDefault,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) =>
      DeliveryTemplate(
        id:        id        ?? this.id,
        shopId:    shopId    ?? this.shopId,
        partnerId: clearPartnerId ? null : (partnerId ?? this.partnerId),
        name:      name      ?? this.name,
        body:      body      ?? this.body,
        isDefault: isDefault ?? this.isDefault,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  // Schema versioning — cf. lib/core/storage/schema_migrator.dart.
  // v2 (hotfix_093) : ajout du champ `partner_id` (nullable). Migration
  // no-op : les anciens records ne portent pas le champ, ils restent
  // shop-wide (partnerId = null).
  static const int currentSchemaVersion = 2;
  static final SchemaMigrator _migrator = SchemaMigrator(
    currentVersion: currentSchemaVersion,
    steps: {
      // v1 → v2 : copie tel quel, partner_id absent reste null.
      2: (m) => {...m},
    },
  );

  Map<String, dynamic> toMap() => {
        'schema_version': currentSchemaVersion,
        'id':         id,
        'shop_id':    shopId,
        'partner_id': partnerId,
        'name':       name,
        'body':       body,
        'is_default': isDefault,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  static DeliveryTemplate fromMap(Map rawM) {
    final m = _migrator.migrate(Map<String, dynamic>.from(rawM));
    return DeliveryTemplate(
        id:        m['id']      as String,
        shopId:    m['shop_id'] as String,
        partnerId: m['partner_id'] as String?,
        name:      (m['name']   ?? '') as String,
        body:      (m['body']   ?? '') as String,
        isDefault: m['is_default'] == true,
        createdAt: DateTime.tryParse(m['created_at']?.toString() ?? '')
                   ?? DateTime.now(),
        updatedAt: DateTime.tryParse(m['updated_at']?.toString() ?? '')
                   ?? DateTime.now(),
      );
  }

  @override
  List<Object?> get props => [id, shopId, partnerId, name, body, isDefault];
}
