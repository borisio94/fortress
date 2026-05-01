import 'package:equatable/equatable.dart';

// ─── Type d'incident ─────────────────────────────────────────────────────────

enum IncidentType {
  scrapped,        // Mise au rebut
  discounted,      // Vente à prix réduit
  inRepair,        // En réparation
  returnSupplier,  // Retour fournisseur
}

extension IncidentTypeX on IncidentType {
  String get label => switch (this) {
    IncidentType.scrapped       => 'Rebut',
    IncidentType.discounted     => 'Prix réduit',
    IncidentType.inRepair       => 'Réparation',
    IncidentType.returnSupplier => 'Retour fournisseur',
  };
  String get key => switch (this) {
    IncidentType.inRepair       => 'in_repair',
    IncidentType.returnSupplier => 'return_supplier',
    _ => name,
  };
  static IncidentType fromString(String? s) => switch (s) {
    'scrapped'        => IncidentType.scrapped,
    'discounted'      => IncidentType.discounted,
    'in_repair'       => IncidentType.inRepair,
    'return_supplier' => IncidentType.returnSupplier,
    _                 => IncidentType.scrapped,
  };
}

// ─── Statut incident ─────────────────────────────────────────────────────────

enum IncidentStatus { pending, inProgress, resolved, cancelled }

extension IncidentStatusX on IncidentStatus {
  String get label => switch (this) {
    IncidentStatus.pending    => 'En attente',
    IncidentStatus.inProgress => 'En cours',
    IncidentStatus.resolved   => 'Résolu',
    IncidentStatus.cancelled  => 'Annulé',
  };
  String get key => switch (this) {
    IncidentStatus.inProgress => 'in_progress',
    _ => name,
  };
  static IncidentStatus fromString(String? s) => switch (s) {
    'in_progress' => IncidentStatus.inProgress,
    'resolved'    => IncidentStatus.resolved,
    'cancelled'   => IncidentStatus.cancelled,
    _             => IncidentStatus.pending,
  };
}

// ─── Incident ────────────────────────────────────────────────────────────────

class Incident extends Equatable {
  final String  id;
  final String  shopId;
  final String? productId;
  final String? variantId;
  final String  productName;
  final IncidentType   type;
  final IncidentStatus status;
  final int     quantity;
  final double  repairCost;
  final double  salePrice;   // prix réduit si type=discounted
  final String? notes;
  final String? receptionId;
  final DateTime? resolvedAt;
  final String? createdBy;
  final DateTime createdAt;

  const Incident({
    required this.id,
    required this.shopId,
    this.productId,
    this.variantId,
    required this.productName,
    required this.type,
    this.status     = IncidentStatus.pending,
    this.quantity   = 1,
    this.repairCost = 0,
    this.salePrice  = 0,
    this.notes,
    this.receptionId,
    this.resolvedAt,
    this.createdBy,
    required this.createdAt,
  });

  bool get isPending  => status == IncidentStatus.pending;
  bool get isResolved => status == IncidentStatus.resolved;

  Map<String, dynamic> toMap() => {
    'id': id, 'shop_id': shopId,
    'product_id': productId, 'variant_id': variantId,
    'product_name': productName,
    'type': type.key, 'status': status.key,
    'quantity': quantity, 'repair_cost': repairCost,
    'sale_price': salePrice,
    'notes': notes, 'reception_id': receptionId,
    'resolved_at': resolvedAt?.toIso8601String(),
    'created_by': createdBy,
    'created_at': createdAt.toIso8601String(),
  };

  factory Incident.fromMap(Map<String, dynamic> m) => Incident(
    id:           m['id'] as String,
    shopId:       m['shop_id'] as String,
    productId:    m['product_id'] as String?,
    variantId:    m['variant_id'] as String?,
    productName:  m['product_name'] as String? ?? '',
    type:         IncidentTypeX.fromString(m['type'] as String?),
    status:       IncidentStatusX.fromString(m['status'] as String?),
    quantity:     m['quantity'] as int? ?? 1,
    repairCost:   (m['repair_cost'] as num?)?.toDouble() ?? 0,
    salePrice:    (m['sale_price'] as num?)?.toDouble() ?? 0,
    notes:        m['notes'] as String?,
    receptionId:  m['reception_id'] as String?,
    resolvedAt:   m['resolved_at'] is String
        ? DateTime.tryParse(m['resolved_at'] as String) : null,
    createdBy:    m['created_by'] as String?,
    createdAt:    DateTime.tryParse(m['created_at']?.toString() ?? '') ?? DateTime.now(),
  );

  @override List<Object?> get props => [id, shopId, type, status, quantity];
}
