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

  /// Options de menu choisies pour cette ligne (module restaurant).
  ///
  /// Chaque entrée : `{group: 'Cuisson', option: 'Saignant', price_impact: 0}`.
  /// **Purement descriptif** : l'impact tarifaire est déjà matérialisé dans
  /// [customPrice] au moment de la prise de commande, pour que les ~9
  /// recalculs de total dispersés dans l'app (dashboard, exports, métriques
  /// client, PDF, tracking web) restent justes sans connaître les modificateurs.
  /// Vide (défaut) pour toute vente non-restaurant → zéro impact e-commerce.
  final List<Map<String, dynamic>> modifiers;

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
    this.modifiers = const [],
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
    List<Map<String, dynamic>>? modifiers,
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
    // Recopié explicitement : ce corps réassigne chaque champ à la main,
    // donc omettre `modifiers` ici l'effacerait silencieusement à chaque
    // copyWith (changement de quantité, clôture de vente à choisir…).
    modifiers:   modifiers   ?? this.modifiers,
  );

  /// Signature stable des options, pour distinguer deux lignes du même
  /// produit commandées avec des options différentes (ex. un steak saignant
  /// et un steak bien cuit ne doivent pas fusionner en une ligne ×2).
  String get modifiersKey {
    if (modifiers.isEmpty) return '';
    final parts = modifiers
        .map((m) => '${m['group'] ?? ''}:${m['option'] ?? ''}')
        .toList()
      ..sort();
    return parts.join('|');
  }

  /// Libellé lisible des options — « Saignant · Sans sauce ».
  String get modifiersLabel => modifiers
      .map((m) => (m['option'] ?? '').toString())
      .where((s) => s.isNotEmpty)
      .join(' · ');

  @override
  List<Object?> get props =>
      [productId, quantity, discount, customPrice, imageUrl, modifiersKey];
}