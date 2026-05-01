import 'package:equatable/equatable.dart';

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
  });

  bool get isAvailable => status == 'available';
  bool get hasIssue    => status == 'damaged' || status == 'defective' || status == 'to_inspect';

  String get statusLabel => switch (status) {
    'available'  => 'Disponible',
    'damaged'    => 'Endommagé',
    'defective'  => 'Défectueux',
    'to_inspect' => 'À inspecter',
    _            => status,
  };

  Map<String, dynamic> toMap() => {
    'id': id, 'variant_id': variantId, 'product_id': productId,
    'shop_id': shopId, 'quantity': quantity, 'status': status,
    'cause': cause.key, 'related_order_id': relatedOrderId,
    'note': note, 'created_by': createdBy,
    'created_at': createdAt.toIso8601String(),
  };

  factory StockArrival.fromMap(Map<String, dynamic> m) => StockArrival(
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
  );

  @override List<Object?> get props => [id, variantId, quantity, status];
}
