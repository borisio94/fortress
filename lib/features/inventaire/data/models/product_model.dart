import '../../domain/entities/product.dart';

// ─── Modèle variante ──────────────────────────────────────────────────────────
class ProductVariantModel {
  final String?  id;
  final String   name;
  final String?  sku;
  final double   priceBuy;
  final double   priceSellPos;
  final double   priceSellWeb;
  final int      stockQty;

  const ProductVariantModel({
    this.id,
    required this.name,
    this.sku,
    this.priceBuy     = 0,
    this.priceSellPos = 0,
    this.priceSellWeb = 0,
    this.stockQty     = 0,
  });

  factory ProductVariantModel.fromMap(Map<String, dynamic> m) => ProductVariantModel(
    id:           m['id']             as String?,
    name:         m['name']           as String,
    sku:          m['sku']            as String?,
    priceBuy:     (m['price_buy']     as num?)?.toDouble() ?? 0,
    priceSellPos: (m['price_sell_pos'] as num?)?.toDouble() ?? 0,
    priceSellWeb: (m['price_sell_web'] as num?)?.toDouble() ?? 0,
    stockQty:     (m['stock_qty']     as num?)?.toInt() ?? 0,
  );

  Map<String, dynamic> toMap() => {
    'id':            id,
    'name':          name,
    'sku':           sku,
    'price_buy':     priceBuy,
    'price_sell_pos':priceSellPos,
    'price_sell_web':priceSellWeb,
    'stock_qty':     stockQty,
  };

  factory ProductVariantModel.fromEntity(ProductVariant v) => ProductVariantModel(
    id:           v.id,
    name:         v.name,
    sku:          v.sku,
    priceBuy:     v.priceBuy,
    priceSellPos: v.priceSellPos,
    priceSellWeb: v.priceSellWeb,
    stockQty:     v.stockQty,
  );

  ProductVariant toEntity() => ProductVariant(
    id:           id,
    name:         name,
    sku:          sku,
    priceBuy:     priceBuy,
    priceSellPos: priceSellPos,
    priceSellWeb: priceSellWeb,
    stockAvailable: stockQty,
    stockPhysical:  stockQty,
  );
}

// ─── Modèle produit ───────────────────────────────────────────────────────────
class ProductModel {
  final String?  id;
  final String?  storeId;
  final String?  categoryId;
  final String?  brand;
  final String   name;
  final String?  description;
  final String?  barcode;
  final String?  sku;
  final double   priceBuy;
  final double   customsFee;
  final double   priceSellPos;
  final double   priceSellWeb;
  final double   taxRate;
  final int      stockQty;
  final int      stockMinAlert;
  final bool     isActive;
  final bool     isVisibleWeb;
  final String?  imageUrl;
  final int      rating;
  final List<ProductVariantModel> variants;

  const ProductModel({
    this.id,
    this.storeId,
    this.categoryId,
    this.brand,
    required this.name,
    this.description,
    this.barcode,
    this.sku,
    this.priceBuy      = 0,
    this.customsFee    = 0,
    this.priceSellPos  = 0,
    this.priceSellWeb  = 0,
    this.taxRate       = 0,
    this.stockQty      = 0,
    this.stockMinAlert = 5,
    this.isActive      = true,
    this.isVisibleWeb  = false,
    this.imageUrl,
    this.rating        = 0,
    this.variants      = const [],
  });

  factory ProductModel.fromMap(Map<String, dynamic> m) => ProductModel(
    id:            m['id']             as String?,
    storeId:       m['store_id']       as String?,
    categoryId:    m['category_id']    as String?,
    brand:         m['brand']          as String?,
    name:          m['name']           as String,
    description:   m['description']    as String?,
    barcode:       m['barcode']        as String?,
    sku:           m['sku']            as String?,
    priceBuy:      (m['price_buy']     as num?)?.toDouble() ?? 0,
    customsFee:    (m['customs_fee']   as num?)?.toDouble() ?? 0,
    priceSellPos:  (m['price_sell_pos'] as num?)?.toDouble() ?? 0,
    priceSellWeb:  (m['price_sell_web'] as num?)?.toDouble() ?? 0,
    taxRate:       (m['tax_rate']      as num?)?.toDouble() ?? 0,
    stockQty:      (m['stock_qty']     as num?)?.toInt() ?? 0,
    stockMinAlert: (m['stock_min_alert'] as num?)?.toInt() ?? 5,
    isActive:      m['is_active']      as bool? ?? true,
    isVisibleWeb:  m['is_visible_web']  as bool? ?? false,
    imageUrl:      m['image_url']      as String?,
    rating:        (m['rating']        as num?)?.toInt() ?? 0,
    variants:      (m['variants'] as List? ?? [])
        .map((v) => ProductVariantModel.fromMap(Map<String, dynamic>.from(v)))
        .toList(),
  );

  Map<String, dynamic> toMap() => {
    'id':             id,
    'store_id':       storeId,
    'category_id':    categoryId,
    'brand':          brand,
    'name':           name,
    'description':    description,
    'barcode':        barcode,
    'sku':            sku,
    'price_buy':      priceBuy,
    'customs_fee':    customsFee,
    'price_sell_pos': priceSellPos,
    'price_sell_web': priceSellWeb,
    'tax_rate':       taxRate,
    'stock_qty':      stockQty,
    'stock_min_alert':stockMinAlert,
    'is_active':      isActive,
    'is_visible_web': isVisibleWeb,
    'image_url':      imageUrl,
    'rating':         rating,
    'variants':       variants.map((v) => v.toMap()).toList(),
  };

  static ProductModel fromEntity(Product p) => ProductModel(
    id:            p.id,
    storeId:       p.storeId,
    categoryId:    p.categoryId,
    brand:         p.brand,
    name:          p.name,
    description:   p.description,
    barcode:       p.barcode,
    sku:           p.sku,
    priceBuy:      p.priceBuy,
    customsFee:    p.customsFee,
    priceSellPos:  p.priceSellPos,
    priceSellWeb:  p.priceSellWeb,
    taxRate:       p.taxRate,
    stockQty:      p.stockQty,
    stockMinAlert: p.stockMinAlert,
    isActive:      p.isActive,
    isVisibleWeb:  p.isVisibleWeb,
    imageUrl:      p.imageUrl,
    rating:        p.rating,
    variants:      p.variants.map(ProductVariantModel.fromEntity).toList(),
  );

  Product toEntity() => Product(
    id:            id,
    storeId:       storeId,
    categoryId:    categoryId,
    brand:         brand,
    name:          name,
    description:   description,
    barcode:       barcode,
    sku:           sku,
    priceBuy:      priceBuy,
    customsFee:    customsFee,
    priceSellPos:  priceSellPos,
    priceSellWeb:  priceSellWeb,
    taxRate:       taxRate,
    stockQty:      stockQty,
    stockMinAlert: stockMinAlert,
    isActive:      isActive,
    isVisibleWeb:  isVisibleWeb,
    imageUrl:      imageUrl,
    rating:        rating,
    variants:      variants.map((v) => v.toEntity()).toList(),
  );
}