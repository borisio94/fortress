import 'package:equatable/equatable.dart';

/// Template de message WhatsApp utilisé pour transférer une commande à un
/// livreur. Le `body` peut contenir des placeholders `{{nom_variable}}`
/// remplacés au moment du transfert par `delivery_message_builder`.
///
/// Variables supportées : caisse, client_name, client_phone, lieu_livraison,
/// produits, date, heure, prix_produit, frais_livraison, total, notes.
///
/// Persistence :
///   • SQL  : table `delivery_templates` (cf. hotfix_049).
///   • Hive : `HiveBoxes.deliveryTemplatesBox` (cache offline, synchronisé
///            via Supabase Realtime).
class DeliveryTemplate extends Equatable {
  final String   id;
  final String   shopId;
  final String   name;
  final String   body;
  /// Un seul template par shop peut avoir `isDefault=true` (index unique
  /// partiel côté SQL). Utilisé en fallback quand aucune attribution
  /// spécifique n'existe pour le destinataire.
  final bool     isDefault;
  final DateTime createdAt;
  final DateTime updatedAt;

  const DeliveryTemplate({
    required this.id,
    required this.shopId,
    required this.name,
    required this.body,
    this.isDefault = false,
    required this.createdAt,
    required this.updatedAt,
  });

  DeliveryTemplate copyWith({
    String?   id,
    String?   shopId,
    String?   name,
    String?   body,
    bool?     isDefault,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) =>
      DeliveryTemplate(
        id:        id        ?? this.id,
        shopId:    shopId    ?? this.shopId,
        name:      name      ?? this.name,
        body:      body      ?? this.body,
        isDefault: isDefault ?? this.isDefault,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toMap() => {
        'id':         id,
        'shop_id':    shopId,
        'name':       name,
        'body':       body,
        'is_default': isDefault,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  static DeliveryTemplate fromMap(Map m) => DeliveryTemplate(
        id:        m['id']      as String,
        shopId:    m['shop_id'] as String,
        name:      (m['name']   ?? '') as String,
        body:      (m['body']   ?? '') as String,
        isDefault: m['is_default'] == true,
        createdAt: DateTime.tryParse(m['created_at']?.toString() ?? '')
                   ?? DateTime.now(),
        updatedAt: DateTime.tryParse(m['updated_at']?.toString() ?? '')
                   ?? DateTime.now(),
      );

  @override
  List<Object?> get props => [id, shopId, name, body, isDefault];
}
