import 'package:equatable/equatable.dart';

// ─── Statut réception ────────────────────────────────────────────────────────

enum ReceptionStatus {
  draft,      // Brouillon
  validated,  // Validée
  cancelled,  // Annulée
}

extension ReceptionStatusX on ReceptionStatus {
  String get label => switch (this) {
    ReceptionStatus.draft     => 'Brouillon',
    ReceptionStatus.validated => 'Validée',
    ReceptionStatus.cancelled => 'Annulée',
  };
  static ReceptionStatus fromString(String? s) => switch (s) {
    'validated' => ReceptionStatus.validated,
    'cancelled' => ReceptionStatus.cancelled,
    _           => ReceptionStatus.draft,
  };
}

// ─── Item de réception ───────────────────────────────────────────────────────

enum ReceptionItemStatus { available, damaged, defective, mixed }

extension ReceptionItemStatusX on ReceptionItemStatus {
  String get label => switch (this) {
    ReceptionItemStatus.available  => 'Conforme',
    ReceptionItemStatus.damaged    => 'Endommagé',
    ReceptionItemStatus.defective  => 'Défectueux',
    ReceptionItemStatus.mixed      => 'Mixte',
  };
  static ReceptionItemStatus fromString(String? s) => switch (s) {
    'damaged'   => ReceptionItemStatus.damaged,
    'defective' => ReceptionItemStatus.defective,
    'mixed'     => ReceptionItemStatus.mixed,
    _           => ReceptionItemStatus.available,
  };
}

class ReceptionItem extends Equatable {
  final String  id;
  final String? productId;
  final String? variantId;
  final String  productName;
  final int     expectedQty;
  final int     receivedQty;
  final int     damagedQty;
  final int     defectiveQty;
  final ReceptionItemStatus status;
  final String? notes;

  const ReceptionItem({
    required this.id,
    this.productId,
    this.variantId,
    required this.productName,
    this.expectedQty  = 0,
    this.receivedQty  = 0,
    this.damagedQty   = 0,
    this.defectiveQty = 0,
    this.status       = ReceptionItemStatus.available,
    this.notes,
  });

  int get conformQty => receivedQty - damagedQty - defectiveQty;
  bool get hasIssues => damagedQty > 0 || defectiveQty > 0;

  Map<String, dynamic> toMap() => {
    'id': id, 'product_id': productId, 'variant_id': variantId,
    'product_name': productName, 'expected_qty': expectedQty,
    'received_qty': receivedQty, 'damaged_qty': damagedQty,
    'defective_qty': defectiveQty, 'status': status.name,
    'notes': notes,
  };

  factory ReceptionItem.fromMap(Map<String, dynamic> m) => ReceptionItem(
    id:           m['id'] as String,
    productId:    m['product_id'] as String?,
    variantId:    m['variant_id'] as String?,
    productName:  m['product_name'] as String? ?? '',
    expectedQty:  m['expected_qty'] as int? ?? 0,
    receivedQty:  m['received_qty'] as int? ?? 0,
    damagedQty:   m['damaged_qty'] as int? ?? 0,
    defectiveQty: m['defective_qty'] as int? ?? 0,
    status:       ReceptionItemStatusX.fromString(m['status'] as String?),
    notes:        m['notes'] as String?,
  );

  @override List<Object?> get props => [id, productId, receivedQty, damagedQty, defectiveQty];
}

// ─── Bon de réception ────────────────────────────────────────────────────────

class Reception extends Equatable {
  final String  id;
  final String  shopId;
  final String? purchaseOrderId;
  final String? supplierId;
  final ReceptionStatus status;
  final List<ReceptionItem> items;
  final String? notes;
  final String? createdBy;
  final DateTime createdAt;

  const Reception({
    required this.id,
    required this.shopId,
    this.purchaseOrderId,
    this.supplierId,
    this.status    = ReceptionStatus.draft,
    this.items     = const [],
    this.notes,
    this.createdBy,
    required this.createdAt,
  });

  int get totalExpected  => items.fold(0, (s, i) => s + i.expectedQty);
  int get totalReceived  => items.fold(0, (s, i) => s + i.receivedQty);
  int get totalDamaged   => items.fold(0, (s, i) => s + i.damagedQty);
  int get totalDefective => items.fold(0, (s, i) => s + i.defectiveQty);
  int get totalConform   => items.fold(0, (s, i) => s + i.conformQty);
  bool get hasIssues     => items.any((i) => i.hasIssues);

  Map<String, dynamic> toMap() => {
    'id': id, 'shop_id': shopId,
    'purchase_order_id': purchaseOrderId,
    'supplier_id': supplierId,
    'status': status.name,
    'items': items.map((i) => i.toMap()).toList(),
    'notes': notes, 'created_by': createdBy,
    'created_at': createdAt.toIso8601String(),
  };

  factory Reception.fromMap(Map<String, dynamic> m) => Reception(
    id:              m['id'] as String,
    shopId:          m['shop_id'] as String,
    purchaseOrderId: m['purchase_order_id'] as String?,
    supplierId:      m['supplier_id'] as String?,
    status:          ReceptionStatusX.fromString(m['status'] as String?),
    items:           ((m['items'] as List?) ?? [])
        .map((e) => ReceptionItem.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList(),
    notes:           m['notes'] as String?,
    createdBy:       m['created_by'] as String?,
    createdAt:       DateTime.tryParse(m['created_at']?.toString() ?? '') ?? DateTime.now(),
  );

  @override List<Object?> get props => [id, shopId, status, items];
}
