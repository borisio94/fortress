import 'package:equatable/equatable.dart';

enum StockMovementType {
  entry,           // Réception / ajout
  sale,            // Vente
  adjustment,      // Ajustement manuel
  incident,        // Incident (casse, rebut)
  repairCost,      // Coût réparation
  returnSupplier,  // Retour fournisseur
  returnClient,    // Retour client
  transfer,        // Transfert entre boutiques
  scrapped,        // Mise au rebut
}

extension StockMovementTypeX on StockMovementType {
  String get label => switch (this) {
    StockMovementType.entry          => 'Entrée',
    StockMovementType.sale           => 'Vente',
    StockMovementType.adjustment     => 'Ajustement',
    StockMovementType.incident       => 'Incident',
    StockMovementType.repairCost     => 'Réparation',
    StockMovementType.returnSupplier => 'Retour fournisseur',
    StockMovementType.returnClient   => 'Retour client',
    StockMovementType.transfer       => 'Transfert',
    StockMovementType.scrapped       => 'Rebut',
  };
  String get key => switch (this) {
    StockMovementType.repairCost     => 'repair_cost',
    StockMovementType.returnSupplier => 'return_supplier',
    StockMovementType.returnClient   => 'return_client',
    _ => name,
  };
  static StockMovementType fromString(String? s) => switch (s) {
    'entry'           => StockMovementType.entry,
    'sale'            => StockMovementType.sale,
    'adjustment'      => StockMovementType.adjustment,
    'incident'        => StockMovementType.incident,
    'repair_cost'     => StockMovementType.repairCost,
    'return_supplier' => StockMovementType.returnSupplier,
    'return_client'   => StockMovementType.returnClient,
    'transfer'        => StockMovementType.transfer,
    'scrapped'        => StockMovementType.scrapped,
    _                 => StockMovementType.adjustment,
  };

  bool get isPositive => this == StockMovementType.entry
      || this == StockMovementType.returnClient
      || this == StockMovementType.adjustment;
}

class StockMovement extends Equatable {
  final String  id;
  final String  shopId;
  final String? productId;
  final String? variantId;
  final StockMovementType type;
  final int     quantity;    // positif = entrée, négatif = sortie
  final double  unitCost;
  final String? reference;   // ID commande, incident, réception…
  final String? notes;
  final String? createdBy;
  final DateTime createdAt;

  const StockMovement({
    required this.id,
    required this.shopId,
    this.productId,
    this.variantId,
    required this.type,
    required this.quantity,
    this.unitCost  = 0,
    this.reference,
    this.notes,
    this.createdBy,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
    'id': id, 'shop_id': shopId,
    'product_id': productId, 'variant_id': variantId,
    'type': type.key, 'quantity': quantity,
    'unit_cost': unitCost, 'reference': reference,
    'notes': notes, 'created_by': createdBy,
    'created_at': createdAt.toIso8601String(),
  };

  factory StockMovement.fromMap(Map<String, dynamic> m) => StockMovement(
    id:        m['id'] as String,
    shopId:    m['shop_id'] as String,
    productId: m['product_id'] as String?,
    variantId: m['variant_id'] as String?,
    type:      StockMovementTypeX.fromString(m['type'] as String?),
    quantity:  m['quantity'] as int? ?? 0,
    unitCost:  (m['unit_cost'] as num?)?.toDouble() ?? 0,
    reference: m['reference'] as String?,
    notes:     m['notes'] as String?,
    createdBy: m['created_by'] as String?,
    createdAt: DateTime.tryParse(m['created_at']?.toString() ?? '') ?? DateTime.now(),
  );

  @override List<Object?> get props => [id, shopId, type, quantity];
}
