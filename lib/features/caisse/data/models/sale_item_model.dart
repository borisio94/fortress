import '../../domain/entities/sale_item.dart';

class SaleItemModel {
  final String  productId;
  final String  productName;
  final String? variantName;
  final String? imageUrl;
  final double  unitPrice;
  final double? customPrice;
  final double  priceBuy;
  final int     quantity;
  final double  discount;

  const SaleItemModel({
    required this.productId,
    required this.productName,
    this.variantName,
    this.imageUrl,
    required this.unitPrice,
    this.customPrice,
    this.priceBuy = 0,
    required this.quantity,
    this.discount = 0,
  });

  factory SaleItemModel.fromMap(Map<String, dynamic> m) => SaleItemModel(
    productId:   m['product_id'] as String,
    productName: m['product_name'] as String,
    variantName: m['variant_name'] as String?,
    imageUrl:    m['image_url'] as String?,
    unitPrice:   (m['unit_price'] as num).toDouble(),
    customPrice: (m['custom_price'] as num?)?.toDouble(),
    priceBuy:    (m['price_buy'] as num?)?.toDouble() ?? 0,
    quantity:    (m['quantity'] as num).toInt(),
    discount:    (m['discount'] as num?)?.toDouble() ?? 0,
  );

  Map<String, dynamic> toMap() => {
    'product_id':   productId,
    'product_name': productName,
    'variant_name': variantName,
    'image_url':    imageUrl,
    'unit_price':   unitPrice,
    'custom_price': customPrice,
    'price_buy':    priceBuy,
    'quantity':     quantity,
    'discount':     discount,
  };

  factory SaleItemModel.fromEntity(SaleItem i) => SaleItemModel(
    productId:   i.productId,
    productName: i.productName,
    variantName: i.variantName,
    imageUrl:    i.imageUrl,
    unitPrice:   i.unitPrice,
    customPrice: i.customPrice,
    priceBuy:    i.priceBuy,
    quantity:    i.quantity,
    discount:    i.discount,
  );

  SaleItem toEntity() => SaleItem(
    productId:   productId,
    productName: productName,
    variantName: variantName,
    imageUrl:    imageUrl,
    unitPrice:   unitPrice,
    customPrice: customPrice,
    priceBuy:    priceBuy,
    quantity:    quantity,
    discount:    discount,
  );
}
