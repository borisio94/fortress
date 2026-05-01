import 'package:equatable/equatable.dart';

class SaleItem extends Equatable {
  final String  productId;
  final String  productName;
  final String? variantName;   // nom de la variante si applicable
  final String? imageUrl;      // image spécifique à la variante
  final double  unitPrice;     // prix de base (du produit/variante)
  final double? customPrice;   // prix modifié pour cette vente uniquement
  final double  priceBuy;      // prix d'achat (pour calcul alerte marge)
  final int     quantity;
  final double  discount;

  const SaleItem({
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

  /// Prix effectif pour cette vente (custom si défini, sinon unitaire)
  double get effectivePrice => customPrice ?? unitPrice;

  double get subtotal => (effectivePrice * quantity) * (1 - discount / 100);

  /// Bénéfice par unité basé sur le prix effectif
  double get profitPerUnit => effectivePrice - priceBuy;

  /// Alerte : le prix custom est en dessous de la moitié du bénéfice normal
  /// Bénéfice normal = unitPrice - priceBuy
  /// Alerte si : profitPerUnit < (unitPrice - priceBuy) / 2
  bool get isPriceAlertTriggered {
    if (customPrice == null) return false;
    if (priceBuy <= 0) return false;
    final normalProfit = unitPrice - priceBuy;
    if (normalProfit <= 0) return false;
    return profitPerUnit < (normalProfit / 2);
  }

  SaleItem copyWith({
    int? quantity,
    double? discount,
    double? customPrice,
    String? imageUrl,
    bool clearCustomPrice = false,
  }) => SaleItem(
    productId:   productId,
    productName: productName,
    variantName: variantName,
    imageUrl:    imageUrl    ?? this.imageUrl,
    unitPrice:   unitPrice,
    customPrice: clearCustomPrice ? null : (customPrice ?? this.customPrice),
    priceBuy:    priceBuy,
    quantity:    quantity    ?? this.quantity,
    discount:    discount    ?? this.discount,
  );

  @override
  List<Object?> get props =>
      [productId, quantity, discount, customPrice, imageUrl];
}