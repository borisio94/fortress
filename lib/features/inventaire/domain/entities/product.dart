import 'package:equatable/equatable.dart';

// ─── Variante de produit ──────────────────────────────────────────────────────

class ProductVariant extends Equatable {
  final String? id;
  final String  name;
  final String? sku;
  final String? barcode;
  final String? supplier;
  final String? supplierRef;
  final double  priceBuy;
  final double  priceSellPos;
  final double  priceSellWeb;

  // ── 4 champs stock ─────────────────────────────────────────────────────
  final int stockOrdered;    // commandé (indicatif)
  final int stockPhysical;   // tout ce qui est arrivé physiquement
  final int stockAvailable;  // vendable (panier + inventaire)
  final int stockBlocked;    // damaged + defective + to_inspect + in_repair

  final int stockMinAlert;
  final String? imageUrl;
  final List<String> secondaryImageUrls;
  final bool    isMain;
  final bool    promoEnabled;
  final double? promoPrice;
  final DateTime? promoStart;
  final DateTime? promoEnd;

  const ProductVariant({
    this.id,
    required this.name,
    this.sku,
    this.barcode,
    this.supplier,
    this.supplierRef,
    this.priceBuy          = 0,
    this.priceSellPos      = 0,
    this.priceSellWeb      = 0,
    this.stockOrdered      = 0,
    this.stockPhysical     = 0,
    this.stockAvailable    = 0,
    this.stockBlocked      = 0,
    this.stockMinAlert     = 1,
    this.imageUrl,
    this.secondaryImageUrls = const [],
    this.isMain            = false,
    this.promoEnabled      = false,
    this.promoPrice,
    this.promoStart,
    this.promoEnd,
  });

  /// Rétrocompatibilité — ancien code qui utilise stockQty
  int get stockQty => stockAvailable;

  double effectivePriceBuy(double expensePerUnit) => priceBuy + expensePerUnit;

  double? get marginPos => priceSellPos > 0
      ? ((priceSellPos - priceBuy) / priceSellPos) * 100
      : null;

  double? get marginWeb => priceSellWeb > 0
      ? ((priceSellWeb - priceBuy) / priceSellWeb) * 100
      : null;

  bool get isLowStock => stockAvailable > 0 && stockAvailable <= stockMinAlert;
  bool get isOutOfStock => stockAvailable <= 0;

  ProductVariant copyWith({
    String? id, String? name, String? sku, String? barcode,
    String? supplier, String? supplierRef,
    double? priceBuy, double? priceSellPos, double? priceSellWeb,
    int? stockOrdered, int? stockPhysical, int? stockAvailable,
    int? stockBlocked, int? stockMinAlert,
    int? stockQty, // rétrocompat → mappe vers stockAvailable
    String? imageUrl,
    List<String>? secondaryImageUrls,
    bool? isMain, bool? promoEnabled, double? promoPrice,
    DateTime? promoStart, DateTime? promoEnd,
  }) => ProductVariant(
    id:                   id                   ?? this.id,
    name:                 name                 ?? this.name,
    sku:                  sku                  ?? this.sku,
    barcode:              barcode              ?? this.barcode,
    supplier:             supplier             ?? this.supplier,
    supplierRef:          supplierRef          ?? this.supplierRef,
    priceBuy:             priceBuy             ?? this.priceBuy,
    priceSellPos:         priceSellPos         ?? this.priceSellPos,
    priceSellWeb:         priceSellWeb         ?? this.priceSellWeb,
    stockOrdered:         stockOrdered         ?? this.stockOrdered,
    stockPhysical:        stockPhysical        ?? this.stockPhysical,
    stockAvailable:       stockAvailable ?? stockQty ?? this.stockAvailable,
    stockBlocked:         stockBlocked         ?? this.stockBlocked,
    stockMinAlert:        stockMinAlert        ?? this.stockMinAlert,
    imageUrl:             imageUrl             ?? this.imageUrl,
    secondaryImageUrls:   secondaryImageUrls   ?? this.secondaryImageUrls,
    isMain:               isMain               ?? this.isMain,
    promoEnabled:         promoEnabled         ?? this.promoEnabled,
    promoPrice:           promoPrice           ?? this.promoPrice,
    promoStart:           promoStart           ?? this.promoStart,
    promoEnd:             promoEnd             ?? this.promoEnd,
  );

  @override
  List<Object?> get props => [id, name, sku, barcode, priceBuy, priceSellPos,
    priceSellWeb, stockAvailable, stockBlocked, imageUrl, isMain, promoEnabled];
}

// ─── Statut produit ──────────────────────────────────────────────────────────

enum ProductStatus {
  available,     // En vente
  discounted,    // Prix réduit / promo
  toInspect,     // À inspecter
  damaged,       // Endommagé
  defective,     // Défectueux
  inRepair,      // En réparation
  scrapped,      // Mis au rebut
  returned,      // Retourné
  discontinued,  // Arrêté / fin de vie
}

extension ProductStatusX on ProductStatus {
  String get label => switch (this) {
    ProductStatus.available    => 'Disponible',
    ProductStatus.discounted   => 'Prix réduit',
    ProductStatus.toInspect    => 'À inspecter',
    ProductStatus.damaged      => 'Endommagé',
    ProductStatus.defective    => 'Défectueux',
    ProductStatus.inRepair     => 'En réparation',
    ProductStatus.scrapped     => 'Rebut',
    ProductStatus.returned     => 'Retourné',
    ProductStatus.discontinued => 'Arrêté',
  };

  /// Nom snake_case pour Supabase / Hive
  String get key => switch (this) {
    ProductStatus.toInspect => 'to_inspect',
    ProductStatus.inRepair  => 'in_repair',
    _ => name,
  };

  /// Parse depuis une string snake_case (Supabase) ou camelCase (Dart)
  static ProductStatus fromString(String? s) => switch (s) {
    'available'    => ProductStatus.available,
    'discounted'   => ProductStatus.discounted,
    'to_inspect'   => ProductStatus.toInspect,
    'damaged'      => ProductStatus.damaged,
    'defective'    => ProductStatus.defective,
    'in_repair'    => ProductStatus.inRepair,
    'scrapped'     => ProductStatus.scrapped,
    'returned'     => ProductStatus.returned,
    'discontinued' => ProductStatus.discontinued,
    _ => ProductStatus.available,
  };

  bool get isSellable  => this == ProductStatus.available || this == ProductStatus.discounted;
  bool get isIncident  => this == ProductStatus.damaged || this == ProductStatus.defective
      || this == ProductStatus.inRepair || this == ProductStatus.scrapped;
}

// ─── Produit ──────────────────────────────────────────────────────────────────

class Product extends Equatable {
  final String?  id;
  final String?  storeId;
  final String?  categoryId;
  final String?  brand;
  final String   name;
  final String?  description;
  final String?  barcode;
  final String?  sku;

  // Tarification
  final double priceBuy;       // Prix d'achat de base (HT)
  final double customsFee;     // Frais de douane répartis sur le stock
  final double priceSellPos;   // Prix de vente caisse
  final double priceSellWeb;   // Prix de vente web/boutique en ligne
  final double taxRate;        // TVA en % (ex: 19.25)

  // Stock
  final int stockQty;          // Quantité en stock
  final int stockMinAlert;     // Seuil d'alerte stock faible

  // Statut
  final ProductStatus status;
  final bool   isActive;
  final bool   isVisibleWeb;
  final String? imageUrl;
  final int    rating;         // 0–5

  // Variantes
  final List<ProductVariant> variants;

  // Dépenses (transport, emballage…) — persistées pour affichage à la modification
  final List<Map<String, dynamic>> expenses;

  /// Horodatage de création côté serveur (Supabase `created_at`).
  /// Optionnel pour rester compatible avec les produits locaux non-sync.
  final DateTime? createdAt;

  const Product({
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
    this.status        = ProductStatus.available,
    this.isActive      = true,
    this.isVisibleWeb  = false,
    this.imageUrl,
    this.rating        = 0,
    this.variants      = const [],
    this.expenses      = const [],
    this.createdAt,
  });

  // ── Propriétés calculées ───────────────────────────────────────────────────

  /// Prix d'achat réel = base + frais de douane par unité
  double get effectivePriceBuy =>
      priceBuy + (stockQty > 0 ? customsFee / stockQty : 0);

  /// Stock disponible total (vendable)
  int get totalStock =>
      variants.isEmpty
          ? stockQty
          : variants.fold(0, (s, v) => s + v.stockAvailable);

  /// Stock bloqué total (damaged + defective + to_inspect + in_repair)
  int get totalBlocked =>
      variants.isEmpty ? 0 : variants.fold(0, (s, v) => s + v.stockBlocked);

  /// Stock physique total
  int get totalPhysical =>
      variants.isEmpty
          ? stockQty
          : variants.fold(0, (s, v) => s + v.stockPhysical);

  /// Image principale = variante marquée isMain, sinon première variante avec image, sinon imageUrl
  String? get mainImageUrl {
    if (variants.isNotEmpty) {
      final main = variants.where((v) => v.isMain).firstOrNull;
      if (main?.imageUrl != null) return main!.imageUrl;
      final withImg = variants.where((v) => v.imageUrl != null).firstOrNull;
      if (withImg != null) return withImg.imageUrl;
    }
    return imageUrl;
  }

  /// Produit en stock faible.
  /// Règle : si AU MOINS UNE variante est sous son propre seuil d'alerte
  /// (stockAvailable > 0 ET ≤ stockMinAlert de la variante).
  /// Sans variante (ancien format), on retombe sur le stock global du produit.
  bool get isLowStock {
    if (variants.isEmpty) {
      return stockQty > 0 && stockQty <= stockMinAlert;
    }
    return variants.any((v) => v.isLowStock);
  }

  /// Produit en rupture
  bool get isOutOfStock => totalStock <= 0;

  /// Marge brute POS en %
  double? get marginPos => priceSellPos > 0 && effectivePriceBuy > 0
      ? ((priceSellPos - effectivePriceBuy) / priceSellPos) * 100
      : null;

  /// Marge brute Web en %
  double? get marginWeb => priceSellWeb > 0 && effectivePriceBuy > 0
      ? ((priceSellWeb - effectivePriceBuy) / priceSellWeb) * 100
      : null;

  /// Prix HT × (1 + taxRate/100)
  double get pricePosTTC => priceSellPos * (1 + taxRate / 100);
  double get priceWebTTC => priceSellWeb * (1 + taxRate / 100);

  // ── CopyWith ───────────────────────────────────────────────────────────────

  Product copyWith({
    String? id, String? storeId, String? categoryId, String? brand,
    String? name, String? description, String? barcode, String? sku,
    double? priceBuy, double? customsFee,
    double? priceSellPos, double? priceSellWeb, double? taxRate,
    int? stockQty, int? stockMinAlert,
    ProductStatus? status,
    bool? isActive, bool? isVisibleWeb,
    String? imageUrl, int? rating,
    List<ProductVariant>? variants,
    List<Map<String, dynamic>>? expenses,
    DateTime? createdAt,
  }) => Product(
    id:           id           ?? this.id,
    storeId:      storeId      ?? this.storeId,
    categoryId:   categoryId   ?? this.categoryId,
    brand:        brand        ?? this.brand,
    name:         name         ?? this.name,
    description:  description  ?? this.description,
    barcode:      barcode      ?? this.barcode,
    sku:          sku          ?? this.sku,
    priceBuy:     priceBuy     ?? this.priceBuy,
    customsFee:   customsFee   ?? this.customsFee,
    priceSellPos: priceSellPos ?? this.priceSellPos,
    priceSellWeb: priceSellWeb ?? this.priceSellWeb,
    taxRate:      taxRate      ?? this.taxRate,
    stockQty:     stockQty     ?? this.stockQty,
    stockMinAlert:stockMinAlert?? this.stockMinAlert,
    status:       status       ?? this.status,
    isActive:     isActive     ?? this.isActive,
    isVisibleWeb: isVisibleWeb ?? this.isVisibleWeb,
    imageUrl:     imageUrl     ?? this.imageUrl,
    rating:       rating       ?? this.rating,
    variants:     variants     ?? this.variants,
    expenses:     expenses     ?? this.expenses,
    createdAt:    createdAt    ?? this.createdAt,
  );

  @override
  List<Object?> get props => [
    id, storeId, name, barcode, sku,
    priceBuy, customsFee, priceSellPos, priceSellWeb, taxRate,
    stockQty, stockMinAlert, status,
    isActive, isVisibleWeb, rating,
    variants, expenses,
  ];
}