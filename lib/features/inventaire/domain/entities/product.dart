import 'dart:async';
import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';

// ─── Rotation des variantes mises en avant (cas d'égalité de stock) ──────────
//
// Quand plusieurs variantes ont le même stock max et qu'aucune n'est marquée
// `isMain` manuellement, on alterne la mise en avant toutes les
// [_featuredRotationPeriod] secondes. Le bucket temporel est partagé entre
// tous les appareils (basé sur `DateTime.now()`), donc deux clients en ligne
// affichent la même variante au même instant.
//
// `featuredRotationTicker` permet à l'UI (grille caisse) de se rebuild quand
// le bucket change, pour que la rotation soit perceptible à l'écran.

const Duration _featuredRotationPeriod = Duration(seconds: 20);

/// Notifier global incrémenté à chaque changement de bucket de rotation.
/// Les widgets qui veulent voir la rotation s'abonnent via
/// `ValueListenableBuilder<int>`. Sinon, `Product.featuredVariant` reste
/// déterministe à un instant T.
final ValueNotifier<int> featuredRotationTicker = ValueNotifier<int>(0);

Timer? _featuredRotationTimer;

void _startFeaturedRotationTicker() {
  if (_featuredRotationTimer != null) return;
  _featuredRotationTimer = Timer.periodic(_featuredRotationPeriod, (_) {
    featuredRotationTicker.value++;
  });
}

// ─── Exception suppression produit (GF-8) ─────────────────────────────────

/// GF-8 — Levée par `AppDatabase.deleteProduct` quand le produit ne peut
/// pas être supprimé. Détaille pourquoi (stock restant, ventes ouvertes,
/// commandes historiques) pour que la dialog UI affiche un message
/// actionnable. Code lisible : `produit_en_stock`.
class ProductNotDeletableException implements Exception {
  final String productName;
  /// Stock disponible total sommé sur toutes les variantes (boutique).
  final int totalAvailable;
  /// Stock physique total sommé sur toutes les variantes.
  final int totalPhysical;
  /// Nombre de commandes OUVERTES (status scheduled/processing) qui
  /// référencent ce produit ou une de ses variantes.
  final int openSalesCount;
  /// Nombre de commandes TOTALES (tous statuts) qui référencent.
  final int totalOrdersCount;

  const ProductNotDeletableException({
    required this.productName,
    this.totalAvailable = 0,
    this.totalPhysical = 0,
    this.openSalesCount = 0,
    this.totalOrdersCount = 0,
  });

  String get code => 'produit_en_stock';

  /// Texte multi-ligne prêt à afficher dans la dialog "Suppression impossible".
  String get message {
    final lines = <String>[];
    if (totalAvailable > 0 || totalPhysical > 0) {
      lines.add('• Stock restant : $totalAvailable disponible '
          '(physique $totalPhysical)');
    }
    if (openSalesCount > 0) {
      lines.add('• Ventes ouvertes : $openSalesCount commande(s) '
          'en attente ou en cours');
    }
    if (totalOrdersCount > 0 && openSalesCount == 0) {
      lines.add('• Historique : référencé dans $totalOrdersCount '
          'commande(s) passée(s)');
    }
    if (lines.isEmpty) {
      return 'Impossible de supprimer pour une raison inconnue.';
    }
    return lines.join('\n');
  }

  @override
  String toString() =>
      'ProductNotDeletableException($productName, $message)';
}

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

  /// Poids et dimensions du colis (grammes, centimètres). Saisis dans la
  /// carte de variante, ils voyagent dans le JSON des variantes : il
  /// n'existe pas de table `product_variants` en base.
  final double? weightG;
  final double? lengthCm;
  final double? widthCm;
  final double? heightCm;

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
    this.weightG,
    this.lengthCm,
    this.widthCm,
    this.heightCm,
  });

  /// Rétrocompatibilité — ancien code qui utilise stockQty
  int get stockQty => stockAvailable;

  double effectivePriceBuy(double expensePerUnit) => priceBuy + expensePerUnit;

  /// `true` si une promotion est RÉELLEMENT en cours sur cette variante.
  ///
  /// Quatre conditions, toutes nécessaires : la promo est activée, un prix
  /// promotionnel existe, l'instant présent tombe dans la fenêtre (bornes
  /// nulles = pas de borne), et ce prix est bien INFÉRIEUR au prix normal —
  /// une « promo » plus chère n'en est pas une.
  ///
  /// Cette règle vivait en privé dans `product_grid_card.dart`, qui l'utilisait
  /// pour AFFICHER un prix barré. Le panier, lui, ne la connaissait pas et
  /// facturait `priceSellPos` : le client voyait une promotion et payait le
  /// plein tarif. Elle est remontée ici pour qu'affichage et facturation
  /// dépendent d'une seule et même vérité.
  bool get isPromoActive {
    if (!promoEnabled || promoPrice == null) return false;
    final now = DateTime.now();
    if (promoStart != null && now.isBefore(promoStart!)) return false;
    if (promoEnd   != null && now.isAfter(promoEnd!))    return false;
    return promoPrice! < priceSellPos;
  }

  /// Prix de vente à APPLIQUER : le prix promotionnel si la promotion est
  /// active, le prix normal sinon. C'est ce montant qui doit être affiché ET
  /// facturé — jamais l'un sans l'autre.
  double get effectiveSellPrice =>
      isPromoActive ? promoPrice! : priceSellPos;

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
    double? weightG, double? lengthCm, double? widthCm, double? heightCm,
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
    weightG:              weightG              ?? this.weightG,
    lengthCm:             lengthCm             ?? this.lengthCm,
    widthCm:              widthCm              ?? this.widthCm,
    heightCm:             heightCm             ?? this.heightCm,
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
  draft,         // Brouillon — fiche commencée, jamais publiée
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
    ProductStatus.draft        => 'Brouillon',
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
    'draft'        => ProductStatus.draft,
    _ => ProductStatus.available,
  };

  /// ⚠ Purement descriptif aujourd'hui : AUCUN appelant dans le code. Les
  /// surfaces de vente filtrent sur `isActive`. Un brouillon est donc exclu
  /// par `isActive: false` + les gardes `!isDraft` posées explicitement.
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

  /// Suivi de stock actif pour cet article (hotfix_138).
  ///
  /// `false` = article produit à la demande — plat cuisiné, service,
  /// prestation : les ventes ne décrémentent rien et les annulations ne
  /// recréditent rien. Sans ce drapeau, vendre un plat dégradait un stock
  /// dénué de sens ou écrivait une ligne `stock_decrement_failed` dans le
  /// journal d'activité à chaque service.
  ///
  /// Défaut `true` : comportement historique préservé pour tout le parc
  /// existant tant que l'utilisateur n'a pas décoché l'option.
  final bool   trackStock;

  /// Activité connexe de rattachement — le « secteur » restaurant
  /// (`restaurant_activities.id`, hotfix_141) : Chawarma · Glace · Bar…
  ///
  /// `null` = plat non rattaché, ou boutique non restaurant : l'e-commerce
  /// n'écrit jamais ce champ. Référence logique, sans FK (offline-first) —
  /// une activité supprimée laisse un id orphelin, traité comme « aucun
  /// secteur » à la lecture.
  final String? activityId;

  final String? imageUrl;
  final int    rating;         // 0–5

  /// Unité de mesure affichée sur la fiche (pièce, kg, litre…). Saisie
  /// depuis toujours, elle n'était jusqu'ici jamais enregistrée.
  final String? unit;

  /// Note de gestion, à usage interne. Jamais exposée par les RPC
  /// publiques ni par le catalogue en ligne.
  final String? internalNotes;

  // Variantes
  final List<ProductVariant> variants;

  // Dépenses (transport, emballage…) — persistées pour affichage à la modification
  final List<Map<String, dynamic>> expenses;

  /// Horodatage de création côté serveur (Supabase `created_at`).
  /// Optionnel pour rester compatible avec les produits locaux non-sync.
  final DateTime? createdAt;

  /// Échéance d'un brouillon. Non-null uniquement quand `status == draft` :
  /// passé cette date, `AppDatabase.init` le supprime. Évite d'accumuler
  /// indéfiniment des fiches jamais terminées.
  final DateTime? draftExpiresAt;

  /// Soft-delete (hotfix_085). Quand non-null, le produit est masqué
  /// des listes membres et n'est plus visible qu'aux super-admins via
  /// l'écran « Produits supprimés ». L'UPDATE est exécuté par la RPC
  /// `delete_product` côté serveur, et propagé en local par realtime +
  /// par le `DeleteProductUseCase` (qui marque Hive immédiatement, sans
  /// attendre l'écho serveur). Le soft-delete force aussi `is_active =
  /// false` et `is_visible_web = false` (la restauration super-admin
  /// laisse ces 2 flags à false → republication manuelle).
  final DateTime? deletedAt;
  final String?   deletedBy;
  final String?   deleteReason;
  /// Snapshot JSONB des champs métier au moment de la suppression
  /// (name, sku, prix, variants…). Lu uniquement par l'écran super-admin
  /// pour afficher la fiche même si la ligne a été altérée depuis.
  final Map<String, dynamic>? archivedSnapshot;

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
    this.trackStock    = true,
    this.activityId,
    this.imageUrl,
    this.rating        = 0,
    this.unit,
    this.internalNotes,
    this.variants      = const [],
    this.expenses      = const [],
    this.createdAt,
    this.draftExpiresAt,
    this.deletedAt,
    this.deletedBy,
    this.deleteReason,
    this.archivedSnapshot,
  });

  /// Fiche commencée puis abandonnée en cours de saisie, conservée pour être
  /// reprise. Jamais vendable, jamais publiée, jamais comptée en alerte.
  bool get isDraft => status == ProductStatus.draft;

  /// True si le produit est soft-deleted (cf. hotfix_085).
  bool get isDeleted => deletedAt != null;

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

  /// Variante mise en avant.
  /// Priorité (ordre revu pour favoriser le stock disponible) :
  ///   1. Variante avec le plus grand `stockAvailable` (parmi celles
  ///      en stock — fallback sur l'ensemble si tout est à 0).
  ///   2. En cas d'égalité de stock, variante explicitement marquée
  ///      `isMain` par l'utilisateur. Si pas de marquée parmi les ex æquo,
  ///      rotation déterministe entre elles selon un bucket temporel de
  ///      [_featuredRotationPeriod].
  /// Renvoie `null` si le produit n'a pas de variantes.
  ///
  /// La rotation n'est visible à l'écran que si l'UI s'abonne à
  /// [featuredRotationTicker] (cf. caisse `_PosProductTile`).
  ProductVariant? featuredVariant({DateTime? now}) {
    if (variants.isEmpty) return null;
    final inStock = variants.where((v) => v.stockAvailable > 0).toList();
    final pool = inStock.isEmpty ? variants : inStock;
    if (pool.length == 1) return pool.first;
    final maxStock =
        pool.fold<int>(0, (m, v) => v.stockAvailable > m ? v.stockAvailable : m);
    final tied = pool.where((v) => v.stockAvailable == maxStock).toList()
      ..sort((a, b) => (a.id ?? a.name).compareTo(b.id ?? b.name));
    if (tied.length == 1) return tied.first;
    // Tie-breaker : variante manuellement mise en avant si présente parmi
    // les ex æquo. Si toutes ont le même stock et qu'aucune n'est `isMain`,
    // on bascule sur la rotation temporelle pour donner sa chance à chacune.
    final manualInTied = tied.where((v) => v.isMain).firstOrNull;
    if (manualInTied != null) return manualInTied;
    // Démarre le ticker à la première utilisation effective de la rotation
    // (idempotent). Si l'UI ne s'abonne pas, le ticker tourne à vide mais le
    // coût est négligeable (un increment toutes les 20s).
    _startFeaturedRotationTicker();
    final t = (now ?? DateTime.now()).millisecondsSinceEpoch ~/
        _featuredRotationPeriod.inMilliseconds;
    return tied[t % tied.length];
  }

  /// Image principale = image de la variante mise en avant, sinon première
  /// variante avec image, sinon imageUrl produit.
  String? get mainImageUrl {
    if (variants.isNotEmpty) {
      final feat = featuredVariant();
      if (feat?.imageUrl != null) return feat!.imageUrl;
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
    // Un brouillon n'est pas encore au catalogue : le faire remonter en
    // alerte de stock ferait sonner la pastille Stock pour une fiche que
    // personne ne vend.
    if (isDraft) return false;
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
    bool? isActive, bool? isVisibleWeb, bool? trackStock,
    String? activityId,
    String? imageUrl, int? rating,
    String? unit, String? internalNotes,
    List<ProductVariant>? variants,
    List<Map<String, dynamic>>? expenses,
    DateTime? createdAt,
    DateTime?              draftExpiresAt,
    DateTime?              deletedAt,
    String?                deletedBy,
    String?                deleteReason,
    Map<String, dynamic>?  archivedSnapshot,
    bool                   clearDeleted = false,
    /// Sort un produit de l'état brouillon (`null` seul vaut « inchangé »).
    bool                   clearDraftExpiry = false,
    /// Détache le plat de son secteur (`activityId` ne peut pas être remis
    /// à null par le passage d'un `null`, interprété comme « inchangé »).
    bool                   clearActivity = false,
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
    trackStock:   trackStock   ?? this.trackStock,
    activityId:   clearActivity ? null : (activityId ?? this.activityId),
    imageUrl:     imageUrl     ?? this.imageUrl,
    rating:       rating       ?? this.rating,
    unit:          unit          ?? this.unit,
    internalNotes: internalNotes ?? this.internalNotes,
    variants:     variants     ?? this.variants,
    expenses:     expenses     ?? this.expenses,
    createdAt:    createdAt    ?? this.createdAt,
    draftExpiresAt: clearDraftExpiry
        ? null : (draftExpiresAt ?? this.draftExpiresAt),
    deletedAt:        clearDeleted ? null : (deletedAt    ?? this.deletedAt),
    deletedBy:        clearDeleted ? null : (deletedBy    ?? this.deletedBy),
    deleteReason:     clearDeleted ? null : (deleteReason ?? this.deleteReason),
    // archivedSnapshot reste TOUJOURS préservé (même au restore) pour
    // traçabilité — c'est le pendant historique de l'audit.
    archivedSnapshot: archivedSnapshot ?? this.archivedSnapshot,
  );

  @override
  List<Object?> get props => [
    id, storeId, name, barcode, sku,
    priceBuy, customsFee, priceSellPos, priceSellWeb, taxRate,
    stockQty, stockMinAlert, status,
    isActive, isVisibleWeb, trackStock, activityId, rating,
    variants, expenses, draftExpiresAt, unit, internalNotes,
  ];
}