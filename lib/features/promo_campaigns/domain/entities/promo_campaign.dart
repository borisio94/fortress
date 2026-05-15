import 'package:equatable/equatable.dart';

// ═════════════════════════════════════════════════════════════════════════════
// PromoCampaign — campagne marketing (promotion ou annonce nouveautés)
// envoyée aux clients via WhatsApp (cf. hotfix_068).
//
// Contient un snapshot des produits au moment de la création : la vitrine
// publique `/promo/:shopId/:campaignId` reste cohérente même si l'admin
// modifie les produits par la suite.
// ═════════════════════════════════════════════════════════════════════════════

enum PromoCampaignType {
  promo,
  news;
}

extension PromoCampaignTypeX on PromoCampaignType {
  String get key => switch (this) {
        PromoCampaignType.promo => 'promo',
        PromoCampaignType.news  => 'news',
      };

  String get label => switch (this) {
        PromoCampaignType.promo => 'Promotion',
        PromoCampaignType.news  => 'Nouveautés',
      };

  static PromoCampaignType fromKey(String? k) => switch (k) {
        'news' => PromoCampaignType.news,
        _      => PromoCampaignType.promo,
      };
}

/// Snapshot d'un produit inclus dans une campagne. Volontairement déconnecté
/// de l'entité Product pour permettre une persistence stable même si le
/// produit est modifié/supprimé après la création de la campagne.
class PromoProductSnapshot extends Equatable {
  final String   productId;
  final String?  variantId;
  final String   name;
  final String?  imageUrl;
  final double   originalPrice;
  /// Si null → on applique [PromoCampaign.discountPercent] global.
  final double?  promoPrice;
  /// Remise calculée individuelle (% par produit). Sinon null = global.
  final int?     discountPercent;

  const PromoProductSnapshot({
    required this.productId,
    this.variantId,
    required this.name,
    this.imageUrl,
    required this.originalPrice,
    this.promoPrice,
    this.discountPercent,
  });

  /// Prix final affiché : promoPrice si défini, sinon original - discount.
  double effectivePrice(int? globalDiscount) {
    if (promoPrice != null) return promoPrice!;
    final d = discountPercent ?? globalDiscount ?? 0;
    if (d <= 0) return originalPrice;
    return originalPrice * (100 - d) / 100;
  }

  Map<String, dynamic> toMap() => {
        'product_id':       productId,
        if (variantId != null) 'variant_id': variantId,
        'name':             name,
        if (imageUrl != null) 'image_url': imageUrl,
        'original_price':   originalPrice,
        if (promoPrice != null) 'promo_price': promoPrice,
        if (discountPercent != null) 'discount_percent': discountPercent,
      };

  static PromoProductSnapshot fromMap(Map m) => PromoProductSnapshot(
        productId:       m['product_id'] as String,
        variantId:       m['variant_id'] as String?,
        name:            (m['name'] ?? '') as String,
        imageUrl:        m['image_url'] as String?,
        originalPrice:
            (m['original_price'] as num?)?.toDouble() ?? 0,
        promoPrice:
            (m['promo_price'] as num?)?.toDouble(),
        discountPercent: (m['discount_percent'] as num?)?.toInt(),
      );

  @override
  List<Object?> get props =>
      [productId, variantId, name, originalPrice, promoPrice, discountPercent];
}

class PromoCampaign extends Equatable {
  final String                  id;
  final String                  shopId;
  final PromoCampaignType       type;
  final String                  name;
  final List<PromoProductSnapshot> products;
  /// Remise globale (% appliqué à tous les produits sans promoPrice
  /// individuel). Null = pas de remise globale (typique news).
  final int?                    discountPercent;
  final DateTime?               validUntil;
  final String?                 description;
  final int                     sentCount;
  final int                     viewCount;
  final DateTime                createdAt;
  final DateTime                updatedAt;

  const PromoCampaign({
    required this.id,
    required this.shopId,
    required this.type,
    required this.name,
    this.products = const [],
    this.discountPercent,
    this.validUntil,
    this.description,
    this.sentCount = 0,
    this.viewCount = 0,
    required this.createdAt,
    required this.updatedAt,
  });

  PromoCampaign copyWith({
    String?                        id,
    String?                        shopId,
    PromoCampaignType?             type,
    String?                        name,
    List<PromoProductSnapshot>?    products,
    int?                           discountPercent,
    DateTime?                      validUntil,
    String?                        description,
    int?                           sentCount,
    int?                           viewCount,
    DateTime?                      createdAt,
    DateTime?                      updatedAt,
  }) =>
      PromoCampaign(
        id:              id              ?? this.id,
        shopId:          shopId          ?? this.shopId,
        type:            type            ?? this.type,
        name:            name            ?? this.name,
        products:        products        ?? this.products,
        discountPercent: discountPercent ?? this.discountPercent,
        validUntil:      validUntil      ?? this.validUntil,
        description:     description     ?? this.description,
        sentCount:       sentCount       ?? this.sentCount,
        viewCount:       viewCount       ?? this.viewCount,
        createdAt:       createdAt       ?? this.createdAt,
        updatedAt:       updatedAt       ?? this.updatedAt,
      );

  Map<String, dynamic> toMap() => {
        'id':               id,
        'shop_id':          shopId,
        'type':             type.key,
        'name':             name,
        'products':         products.map((p) => p.toMap()).toList(),
        if (discountPercent != null) 'discount_percent': discountPercent,
        if (validUntil != null) 'valid_until': validUntil!.toIso8601String(),
        if (description != null) 'description': description,
        'sent_count':       sentCount,
        'view_count':       viewCount,
        'created_at':       createdAt.toIso8601String(),
        'updated_at':       updatedAt.toIso8601String(),
      };

  static PromoCampaign fromMap(Map m) => PromoCampaign(
        id:              m['id']      as String,
        shopId:          m['shop_id'] as String,
        type:            PromoCampaignTypeX.fromKey(m['type']?.toString()),
        name:            (m['name'] ?? '') as String,
        products:        ((m['products'] as List?) ?? const [])
            .whereType<Map>()
            .map((p) => PromoProductSnapshot.fromMap(
                Map<String, dynamic>.from(p)))
            .toList(),
        discountPercent: (m['discount_percent'] as num?)?.toInt(),
        validUntil:      m['valid_until'] != null
            ? DateTime.tryParse(m['valid_until'].toString())
            : null,
        description:     m['description'] as String?,
        sentCount:       (m['sent_count'] as num?)?.toInt() ?? 0,
        viewCount:       (m['view_count'] as num?)?.toInt() ?? 0,
        createdAt:       DateTime.tryParse(
                m['created_at']?.toString() ?? '')
            ?? DateTime.now(),
        updatedAt:       DateTime.tryParse(
                m['updated_at']?.toString() ?? '')
            ?? DateTime.now(),
      );

  @override
  List<Object?> get props => [
        id, shopId, type, name, products, discountPercent,
        validUntil, sentCount, viewCount,
      ];
}
