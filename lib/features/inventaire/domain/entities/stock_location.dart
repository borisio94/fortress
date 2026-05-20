import 'package:equatable/equatable.dart';

/// Type d'emplacement de stockage.
/// - [shop]      : boutique / point de vente (créée automatiquement pour chaque Shop)
/// - [warehouse] : entrepôt / magasin central pouvant alimenter N boutiques
/// - [partner]   : dépôt externe (société de livraison, partenaire) stockant
///                 quelques pièces pour accélérer les livraisons
enum StockLocationType { shop, warehouse, partner }

extension StockLocationTypeX on StockLocationType {
  String get key => switch (this) {
    StockLocationType.shop      => 'shop',
    StockLocationType.warehouse => 'warehouse',
    StockLocationType.partner   => 'partner',
  };

  String get labelFr => switch (this) {
    StockLocationType.shop      => 'Boutique',
    StockLocationType.warehouse => 'Magasin',
    StockLocationType.partner   => 'Dépôt partenaire',
  };

  static StockLocationType fromKey(String? k) => switch (k) {
    'warehouse' => StockLocationType.warehouse,
    'partner'   => StockLocationType.partner,
    _           => StockLocationType.shop,
  };
}

/// Emplacement physique où du stock peut être entreposé.
///
/// Un [ownerId] regroupe toutes les locations d'un même propriétaire
/// (boutiques, magasins, dépôts partenaires) — il correspond au user
/// Supabase qui détient les boutiques.
///
/// Une location `type == shop` est liée à une `shopId` précise.
/// Un warehouse peut alimenter plusieurs shops via le champ
/// [parentWarehouseId] sur ces shops (relation shop → warehouse parent,
/// gérée côté StockLocation des shops).
class StockLocation extends Equatable {
  final String id;
  final String ownerId;
  final StockLocationType type;
  final String name;

  /// Pour type == shop : id de la boutique liée. Null sinon.
  final String? shopId;

  /// Pour type == shop : warehouse qui l'alimente (optionnel).
  /// Pour warehouse/partner : toujours null.
  final String? parentWarehouseId;

  final String? address;
  /// Ville où se trouve le dépôt (séparé d'`address` depuis hotfix_051).
  /// Utilisé pour pré-remplir `{{ville_expedition}}` lors du transfert.
  final String? city;
  /// Quartier ou zone précise dans la ville.
  final String? district;
  final String? phone;
  final String? contactName;
  final String? notes;
  final bool    isActive;
  final DateTime createdAt;
  /// Template de message de transfert assigné à ce partenaire (cf. hotfix_049).
  /// Null = utilise le template par défaut du shop.
  final String? deliveryTemplateId;
  /// Lien d'invitation au groupe WhatsApp partagé avec ce partenaire
  /// (`https://chat.whatsapp.com/<code>`). Si non null, le sheet de
  /// transfert affiche les boutons "Copier message" + "Ouvrir groupe"
  /// au lieu de l'envoi 1-à-1 (cf. hotfix_050).
  final String? whatsappGroupUrl;

  const StockLocation({
    required this.id,
    required this.ownerId,
    required this.type,
    required this.name,
    this.shopId,
    this.parentWarehouseId,
    this.address,
    this.city,
    this.district,
    this.phone,
    this.contactName,
    this.notes,
    this.isActive = true,
    required this.createdAt,
    this.deliveryTemplateId,
    this.whatsappGroupUrl,
  });

  StockLocation copyWith({
    String? name,
    String? parentWarehouseId,
    String? address, String? city, String? district,
    String? phone, String? contactName, String? notes,
    bool? isActive,
    String? deliveryTemplateId,
    String? whatsappGroupUrl,
    bool clearWhatsappGroupUrl = false,
    bool clearPhone            = false,
    bool clearCity             = false,
    bool clearDistrict         = false,
  }) => StockLocation(
    id:                id,
    ownerId:           ownerId,
    type:              type,
    name:              name ?? this.name,
    shopId:            shopId,
    parentWarehouseId: parentWarehouseId ?? this.parentWarehouseId,
    address:           address ?? this.address,
    city:              clearCity     ? null : (city     ?? this.city),
    district:          clearDistrict ? null : (district ?? this.district),
    phone:             clearPhone ? null : (phone ?? this.phone),
    contactName:       contactName ?? this.contactName,
    notes:             notes ?? this.notes,
    isActive:          isActive ?? this.isActive,
    createdAt:         createdAt,
    deliveryTemplateId: deliveryTemplateId ?? this.deliveryTemplateId,
    whatsappGroupUrl:   clearWhatsappGroupUrl
        ? null
        : (whatsappGroupUrl ?? this.whatsappGroupUrl),
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'owner_id': ownerId,
    'type': type.key,
    'name': name,
    'shop_id': shopId,
    'parent_warehouse_id': parentWarehouseId,
    'address': address,
    'city':     city,
    'district': district,
    'phone': phone,
    'contact_name': contactName,
    'notes': notes,
    'is_active': isActive,
    'created_at': createdAt.toIso8601String(),
    'delivery_template_id': deliveryTemplateId,
    'whatsapp_group_url':   whatsappGroupUrl,
  };

  factory StockLocation.fromMap(Map<String, dynamic> m) => StockLocation(
    id:                m['id'] as String,
    ownerId:           m['owner_id'] as String? ?? '',
    type:              StockLocationTypeX.fromKey(m['type'] as String?),
    name:              m['name'] as String? ?? '',
    shopId:            m['shop_id'] as String?,
    parentWarehouseId: m['parent_warehouse_id'] as String?,
    address:           m['address'] as String?,
    city:              m['city']     as String?,
    district:          m['district'] as String?,
    phone:             m['phone'] as String?,
    contactName:       m['contact_name'] as String?,
    notes:             m['notes'] as String?,
    isActive:          m['is_active'] as bool? ?? true,
    createdAt:         DateTime.tryParse(m['created_at']?.toString() ?? '')
                       ?? DateTime.now(),
    deliveryTemplateId: m['delivery_template_id'] as String?,
    whatsappGroupUrl:   m['whatsapp_group_url']   as String?,
  );

  @override
  List<Object?> get props => [id, ownerId, type, name, shopId, isActive];
}
