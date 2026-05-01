import 'package:equatable/equatable.dart';

// ─── Statut commande fournisseur ─────────────────────────────────────────────

enum POStatus {
  draft, sent, confirmed, inTransit, received, cancelled,
}

extension POStatusX on POStatus {
  String get label => switch (this) {
    POStatus.draft     => 'Brouillon',
    POStatus.sent      => 'Envoyée',
    POStatus.confirmed => 'Confirmée',
    POStatus.inTransit => 'En transit',
    POStatus.received  => 'Reçue',
    POStatus.cancelled => 'Annulée',
  };
  String get key => switch (this) {
    POStatus.inTransit => 'in_transit',
    _ => name,
  };
  static POStatus fromString(String? s) => switch (s) {
    'draft'      => POStatus.draft,
    'sent'       => POStatus.sent,
    'confirmed'  => POStatus.confirmed,
    'in_transit' => POStatus.inTransit,
    'received'   => POStatus.received,
    'cancelled'  => POStatus.cancelled,
    _            => POStatus.draft,
  };
  bool get isEditable => this == POStatus.draft;
  bool get canReceive => this == POStatus.confirmed || this == POStatus.inTransit;
}

// ─── Item de commande ────────────────────────────────────────────────────────

class POItem extends Equatable {
  final String  id;
  final String? productId;
  final String? variantId;
  final String  productName;
  final int     quantity;
  final double  unitPrice;
  final int     receivedQty;
  final int     damagedQty;
  final String? notes;

  const POItem({
    required this.id,
    this.productId,
    this.variantId,
    required this.productName,
    this.quantity    = 0,
    this.unitPrice   = 0,
    this.receivedQty = 0,
    this.damagedQty  = 0,
    this.notes,
  });

  double get lineTotal => quantity * unitPrice;

  Map<String, dynamic> toMap() => {
    'id': id, 'product_id': productId, 'variant_id': variantId,
    'product_name': productName, 'quantity': quantity,
    'unit_price': unitPrice, 'received_qty': receivedQty,
    'damaged_qty': damagedQty, 'notes': notes,
  };

  factory POItem.fromMap(Map<String, dynamic> m) => POItem(
    id:          m['id'] as String,
    productId:   m['product_id'] as String?,
    variantId:   m['variant_id'] as String?,
    productName: m['product_name'] as String? ?? '',
    quantity:    m['quantity'] as int? ?? 0,
    unitPrice:   (m['unit_price'] as num?)?.toDouble() ?? 0,
    receivedQty: m['received_qty'] as int? ?? 0,
    damagedQty:  m['damaged_qty'] as int? ?? 0,
    notes:       m['notes'] as String?,
  );

  @override List<Object?> get props => [id, productId, quantity];
}

// ─── Commande fournisseur ────────────────────────────────────────────────────

class PurchaseOrder extends Equatable {
  final String   id;
  final String   shopId;
  final String?  supplierId;
  final POStatus status;
  final List<POItem> items;
  final String?  notes;
  final DateTime? expectedAt;
  final double   totalAmount;
  final String?  createdBy;
  final DateTime createdAt;
  final DateTime updatedAt;

  const PurchaseOrder({
    required this.id,
    required this.shopId,
    this.supplierId,
    this.status      = POStatus.draft,
    this.items       = const [],
    this.notes,
    this.expectedAt,
    this.totalAmount = 0,
    this.createdBy,
    required this.createdAt,
    required this.updatedAt,
  });

  double get computedTotal => items.fold(0.0, (s, i) => s + i.lineTotal);

  Map<String, dynamic> toMap() => {
    'id': id, 'shop_id': shopId, 'supplier_id': supplierId,
    'status': status.key, 'items': items.map((i) => i.toMap()).toList(),
    'notes': notes, 'expected_at': expectedAt?.toIso8601String(),
    'total_amount': computedTotal, 'created_by': createdBy,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
  };

  factory PurchaseOrder.fromMap(Map<String, dynamic> m) => PurchaseOrder(
    id:          m['id'] as String,
    shopId:      m['shop_id'] as String,
    supplierId:  m['supplier_id'] as String?,
    status:      POStatusX.fromString(m['status'] as String?),
    items:       ((m['items'] as List?) ?? [])
        .map((e) => POItem.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList(),
    notes:       m['notes'] as String?,
    expectedAt:  m['expected_at'] is String
        ? DateTime.tryParse(m['expected_at'] as String) : null,
    totalAmount: (m['total_amount'] as num?)?.toDouble() ?? 0,
    createdBy:   m['created_by'] as String?,
    createdAt:   DateTime.tryParse(m['created_at']?.toString() ?? '') ?? DateTime.now(),
    updatedAt:   DateTime.tryParse(m['updated_at']?.toString() ?? '') ?? DateTime.now(),
  );

  @override List<Object?> get props => [id, shopId, status, items];
}
