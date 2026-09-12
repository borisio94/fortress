import 'package:equatable/equatable.dart';
import '../../../../core/storage/schema_migrator.dart';

// ─── Cause d'arrivée ─────────────────────────────────────────────────────────

enum ArrivalCause {
  supplierDelivery,  // Livraison fournisseur
  clientReturn,      // Retour client
  shopTransfer,      // Transfert entre boutiques
  directRestock,     // Réapprovisionnement direct
  other,             // Autre
}

extension ArrivalCauseX on ArrivalCause {
  String get label => switch (this) {
    ArrivalCause.supplierDelivery => 'Livraison fournisseur',
    ArrivalCause.clientReturn     => 'Retour client',
    ArrivalCause.shopTransfer     => 'Transfert boutique',
    ArrivalCause.directRestock    => 'Réappro. direct',
    ArrivalCause.other            => 'Autre',
  };
  String get key => switch (this) {
    ArrivalCause.supplierDelivery => 'supplier_delivery',
    ArrivalCause.clientReturn     => 'client_return',
    ArrivalCause.shopTransfer     => 'shop_transfer',
    ArrivalCause.directRestock    => 'direct_restock',
    ArrivalCause.other            => 'other',
  };
  static ArrivalCause fromString(String? s) => switch (s) {
    'supplier_delivery' => ArrivalCause.supplierDelivery,
    'supplier_order'    => ArrivalCause.supplierDelivery, // rétrocompat → remappe
    'client_return'     => ArrivalCause.clientReturn,
    'shop_transfer'     => ArrivalCause.shopTransfer,
    'direct_restock'    => ArrivalCause.directRestock,
    'other'             => ArrivalCause.other,
    _                   => ArrivalCause.directRestock,
  };
}

// ─── Arrivée en stock ────────────────────────────────────────────────────────

class StockArrival extends Equatable {
  final String  id;
  final String? variantId;
  final String? productId;
  final String  shopId;
  final int     quantity;
  final String  status;   // available, damaged, defective, to_inspect
  final ArrivalCause cause;
  final String? relatedOrderId;
  final String? note;
  final String? createdBy;
  final DateTime createdAt;

  /// Coût d'achat TOTAL de la vague (pas unitaire) — ce que la marchandise
  /// a coûté pour [quantity] pièces. `0` = vague jamais valorisée.
  final double purchaseTotal;

  /// Dépenses rattachées à cette vague : transport, douane, manutention.
  /// Elles se répartissent sur les pièces, elles ne s'ajoutent pas au prix
  /// d'une seule.
  final double feesTotal;

  const StockArrival({
    required this.id,
    this.variantId,
    this.productId,
    required this.shopId,
    required this.quantity,
    this.status    = 'available',
    this.cause     = ArrivalCause.directRestock,
    this.relatedOrderId,
    this.note,
    this.createdBy,
    required this.createdAt,
    this.purchaseTotal = 0,
    this.feesTotal     = 0,
  });

  bool get isAvailable => status == 'available';
  bool get hasIssue    => status == 'damaged' || status == 'defective' || status == 'to_inspect';

  /// `true` si la vague porte un coût exploitable. Les arrivées saisies
  /// avant l'introduction de ces champs renvoient `false` et sont donc
  /// exclues du calcul du prix de revient — on ne leur invente pas un coût.
  bool get isCosted => quantity > 0 && (purchaseTotal > 0 || feesTotal > 0);

  /// Coût de revient unitaire de la vague : marchandise + dépenses, réparti
  /// par pièce. C'est la valeur qui entre dans la moyenne pondérée.
  double get landedUnitCost =>
      quantity > 0 ? (purchaseTotal + feesTotal) / quantity : 0;

  StockArrival copyWith({
    int? quantity,
    String? status,
    ArrivalCause? cause,
    String? note,
    double? purchaseTotal,
    double? feesTotal,
  }) => StockArrival(
    id:             id,
    variantId:      variantId,
    productId:      productId,
    shopId:         shopId,
    quantity:       quantity ?? this.quantity,
    status:         status   ?? this.status,
    cause:          cause    ?? this.cause,
    relatedOrderId: relatedOrderId,
    note:           note     ?? this.note,
    createdBy:      createdBy,
    createdAt:      createdAt,
    purchaseTotal:  purchaseTotal ?? this.purchaseTotal,
    feesTotal:      feesTotal     ?? this.feesTotal,
  );

  String get statusLabel => switch (status) {
    'available'  => 'Disponible',
    'damaged'    => 'Endommagé',
    'defective'  => 'Défectueux',
    'to_inspect' => 'À inspecter',
    _            => status,
  };

  // Schema versioning — cf. lib/core/storage/schema_migrator.dart.
  // v1 → v2 : ajout de `purchase_total` / `fees_total` (valorisation de la
  // vague). Les arrivées existantes n'ont pas de coût connu : on les pose à
  // 0, ce qui les rend `isCosted == false` et les exclut du calcul du prix
  // de revient. Leur inventer un coût fausserait la moyenne pondérée.
  static const int currentSchemaVersion = 2;
  static final SchemaMigrator _migrator = SchemaMigrator(
    currentVersion: currentSchemaVersion,
    steps: {
      // Indexée par la version de DÉPART : transforme un map v1 en v2.
      1: (m) {
        m['purchase_total'] ??= 0;
        m['fees_total']     ??= 0;
        return m;
      },
    },
  );

  Map<String, dynamic> toMap() => {
    'schema_version': currentSchemaVersion,
    'id': id, 'variant_id': variantId, 'product_id': productId,
    'shop_id': shopId, 'quantity': quantity, 'status': status,
    'cause': cause.key, 'related_order_id': relatedOrderId,
    'note': note, 'created_by': createdBy,
    'created_at': createdAt.toIso8601String(),
    'purchase_total': purchaseTotal,
    'fees_total':     feesTotal,
  };

  factory StockArrival.fromMap(Map<String, dynamic> rawM) {
    final m = _migrator.migrate(rawM);
    return StockArrival(
      id:             m['id'] as String,
      variantId:      m['variant_id'] as String?,
      productId:      m['product_id'] as String?,
      shopId:         m['shop_id'] as String,
      quantity:       m['quantity'] as int? ?? 0,
      status:         m['status'] as String? ?? 'available',
      cause:          ArrivalCauseX.fromString(m['cause'] as String?),
      relatedOrderId: m['related_order_id'] as String?,
      note:           m['note'] as String?,
      createdBy:      m['created_by'] as String?,
      createdAt:      DateTime.tryParse(m['created_at']?.toString() ?? '') ?? DateTime.now(),
      purchaseTotal:  (m['purchase_total'] as num?)?.toDouble() ?? 0,
      feesTotal:      (m['fees_total']     as num?)?.toDouble() ?? 0,
    );
  }

  @override List<Object?> get props =>
      [id, variantId, quantity, status, purchaseTotal, feesTotal];
}
