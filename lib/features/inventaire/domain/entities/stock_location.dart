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
  final String? phone;
  final String? contactName;
  final String? notes;
  final bool    isActive;
  final DateTime createdAt;

  const StockLocation({
    required this.id,
    required this.ownerId,
    required this.type,
    required this.name,
    this.shopId,
    this.parentWarehouseId,
    this.address,
    this.phone,
    this.contactName,
    this.notes,
    this.isActive = true,
    required this.createdAt,
  });

  StockLocation copyWith({
    String? name,
    String? parentWarehouseId,
    String? address, String? phone, String? contactName, String? notes,
    bool? isActive,
  }) => StockLocation(
    id:                id,
    ownerId:           ownerId,
    type:              type,
    name:              name ?? this.name,
    shopId:            shopId,
    parentWarehouseId: parentWarehouseId ?? this.parentWarehouseId,
    address:           address ?? this.address,
    phone:             phone ?? this.phone,
    contactName:       contactName ?? this.contactName,
    notes:             notes ?? this.notes,
    isActive:          isActive ?? this.isActive,
    createdAt:         createdAt,
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'owner_id': ownerId,
    'type': type.key,
    'name': name,
    'shop_id': shopId,
    'parent_warehouse_id': parentWarehouseId,
    'address': address,
    'phone': phone,
    'contact_name': contactName,
    'notes': notes,
    'is_active': isActive,
    'created_at': createdAt.toIso8601String(),
  };

  factory StockLocation.fromMap(Map<String, dynamic> m) => StockLocation(
    id:                m['id'] as String,
    ownerId:           m['owner_id'] as String? ?? '',
    type:              StockLocationTypeX.fromKey(m['type'] as String?),
    name:              m['name'] as String? ?? '',
    shopId:            m['shop_id'] as String?,
    parentWarehouseId: m['parent_warehouse_id'] as String?,
    address:           m['address'] as String?,
    phone:             m['phone'] as String?,
    contactName:       m['contact_name'] as String?,
    notes:             m['notes'] as String?,
    isActive:          m['is_active'] as bool? ?? true,
    createdAt:         DateTime.tryParse(m['created_at']?.toString() ?? '')
                       ?? DateTime.now(),
  );

  @override
  List<Object?> get props => [id, ownerId, type, name, shopId, isActive];
}
