import 'package:equatable/equatable.dart';

/// Stock d'une variante de produit dans une [StockLocation] précise.
///
/// Remplace progressivement les champs `stockAvailable/physical/blocked/ordered`
/// portés directement par `ProductVariant`. Pendant la Phase 1 de migration,
/// les deux co-existent : la variante conserve des valeurs "fallback", les
/// StockLevel deviennent la source de vérité multi-location.
///
/// L'unicité est garantie par la paire (variantId, locationId).
class StockLevel extends Equatable {
  final String id;
  final String variantId;
  final String locationId;

  /// `shopId` dénormalisé pour faciliter les filtres par boutique et
  /// les policies RLS Supabase. Pour une location type `warehouse` ou
  /// `partner`, on y met le shop "propriétaire" historique (le premier
  /// créé du ownerId) ou null selon le contexte.
  final String? shopId;

  final int stockAvailable;
  final int stockPhysical;
  final int stockBlocked;
  final int stockOrdered;

  final DateTime updatedAt;

  const StockLevel({
    required this.id,
    required this.variantId,
    required this.locationId,
    this.shopId,
    this.stockAvailable = 0,
    this.stockPhysical  = 0,
    this.stockBlocked   = 0,
    this.stockOrdered   = 0,
    required this.updatedAt,
  });

  StockLevel copyWith({
    int? stockAvailable,
    int? stockPhysical,
    int? stockBlocked,
    int? stockOrdered,
    DateTime? updatedAt,
  }) => StockLevel(
    id:             id,
    variantId:      variantId,
    locationId:     locationId,
    shopId:         shopId,
    stockAvailable: stockAvailable ?? this.stockAvailable,
    stockPhysical:  stockPhysical  ?? this.stockPhysical,
    stockBlocked:   stockBlocked   ?? this.stockBlocked,
    stockOrdered:   stockOrdered   ?? this.stockOrdered,
    updatedAt:      updatedAt      ?? this.updatedAt,
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'variant_id': variantId,
    'location_id': locationId,
    'shop_id': shopId,
    'stock_available': stockAvailable,
    'stock_physical':  stockPhysical,
    'stock_blocked':   stockBlocked,
    'stock_ordered':   stockOrdered,
    'updated_at': updatedAt.toIso8601String(),
  };

  factory StockLevel.fromMap(Map<String, dynamic> m) => StockLevel(
    id:             m['id'] as String,
    variantId:      m['variant_id'] as String? ?? '',
    locationId:     m['location_id'] as String? ?? '',
    shopId:         m['shop_id'] as String?,
    stockAvailable: (m['stock_available'] as num?)?.toInt() ?? 0,
    stockPhysical:  (m['stock_physical']  as num?)?.toInt() ?? 0,
    stockBlocked:   (m['stock_blocked']   as num?)?.toInt() ?? 0,
    stockOrdered:   (m['stock_ordered']   as num?)?.toInt() ?? 0,
    updatedAt:      DateTime.tryParse(m['updated_at']?.toString() ?? '')
                    ?? DateTime.now(),
  );

  @override
  List<Object?> get props => [id, variantId, locationId];
}
