import 'package:equatable/equatable.dart';
import '../../../../core/storage/schema_migrator.dart';

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

// ─── Frais du lot ────────────────────────────────────────────────────────────

/// Frais accessoire d'un arrivage : transport, douane, manutention…
///
/// Ces frais portent sur le LOT ENTIER, pas sur un produit précis — c'est
/// toute leur raison d'être. Ils sont répartis à parts égales sur chaque
/// PIÈCE reçue (et non au prorata de la valeur) : une pièce transportée
/// coûte le même transport qu'une autre, quelle que soit sa valeur
/// marchande. Cf. `ArrivalCostingService`.
class ReceptionFee extends Equatable {
  final String label;
  final double amount;

  const ReceptionFee({required this.label, this.amount = 0});

  Map<String, dynamic> toMap() => {'label': label, 'amount': amount};

  factory ReceptionFee.fromMap(Map<String, dynamic> m) => ReceptionFee(
    label:  m['label'] as String? ?? '',
    amount: (m['amount'] as num?)?.toDouble() ?? 0,
  );

  @override List<Object?> get props => [label, amount];
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

  /// Prix d'achat unitaire NÉGOCIÉ pour cette ligne, hors frais accessoires
  /// (schema v2). `0` = non saisi → la ligne n'apporte que du stock, aucun
  /// recalcul de coût n'est appliqué au produit.
  final double  unitCost;

  /// Coût de revient unitaire FIGÉ à la validation :
  /// `unitCost + frais_du_lot / nombre_total_de_pièces` (schema v2).
  /// Conservé pour l'historique — le coût du produit bouge ensuite au gré
  /// des arrivages suivants (moyenne pondérée), pas celui-ci.
  final double  landedUnitCost;

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
    this.unitCost       = 0,
    this.landedUnitCost = 0,
  });

  int get conformQty => receivedQty - damagedQty - defectiveQty;
  bool get hasIssues => damagedQty > 0 || defectiveQty > 0;

  /// Quantité retenue pour le calcul du coût : le reçu dès qu'il est saisi,
  /// l'attendu tant que le bon est en brouillon (aperçu avant validation).
  int get costingQty => receivedQty > 0 ? receivedQty : expectedQty;

  ReceptionItem copyWith({
    int? receivedQty,
    double? unitCost,
    double? landedUnitCost,
    ReceptionItemStatus? status,
  }) => ReceptionItem(
    id: id, productId: productId, variantId: variantId,
    productName: productName, expectedQty: expectedQty,
    receivedQty:    receivedQty    ?? this.receivedQty,
    damagedQty:     damagedQty,
    defectiveQty:   defectiveQty,
    status:         status         ?? this.status,
    notes:          notes,
    unitCost:       unitCost       ?? this.unitCost,
    landedUnitCost: landedUnitCost ?? this.landedUnitCost,
  );

  Map<String, dynamic> toMap() => {
    'id': id, 'product_id': productId, 'variant_id': variantId,
    'product_name': productName, 'expected_qty': expectedQty,
    'received_qty': receivedQty, 'damaged_qty': damagedQty,
    'defective_qty': defectiveQty, 'status': status.name,
    'notes': notes,
    'unit_cost': unitCost, 'landed_unit_cost': landedUnitCost,
  };

  factory ReceptionItem.fromMap(Map<String, dynamic> m) => ReceptionItem(
    id:           m['id'] as String,
    productId:    m['product_id'] as String?,
    variantId:    m['variant_id'] as String?,
    productName:  m['product_name'] as String? ?? '',
    expectedQty:  (m['expected_qty'] as num?)?.toInt() ?? 0,
    receivedQty:  (m['received_qty'] as num?)?.toInt() ?? 0,
    damagedQty:   (m['damaged_qty'] as num?)?.toInt() ?? 0,
    defectiveQty: (m['defective_qty'] as num?)?.toInt() ?? 0,
    status:       ReceptionItemStatusX.fromString(m['status'] as String?),
    notes:        m['notes'] as String?,
    unitCost:       (m['unit_cost'] as num?)?.toDouble() ?? 0,
    landedUnitCost: (m['landed_unit_cost'] as num?)?.toDouble() ?? 0,
  );

  @override List<Object?> get props => [id, productId, receivedQty, damagedQty,
      defectiveQty, unitCost, landedUnitCost];
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

  /// Frais accessoires du LOT (transport, douane, manutention…) — schema v2.
  /// Répartis par pièce à la validation, cf. `ArrivalCostingService`.
  final List<ReceptionFee> fees;

  /// Bon de FRAIS SEULS (schema v3) — la marchandise est DÉJÀ en stock.
  ///
  /// Cas réel : la facture du transporteur ou le quittus de douane arrive
  /// après la marchandise, parfois des semaines plus tard. Le stock est
  /// entré depuis longtemps ; seul le coût reste à corriger.
  ///
  /// Un tel bon ne fait entrer AUCUNE quantité : les `receivedQty`
  /// désignent les pièces à qui répartir les frais, pas des unités qui
  /// arrivent. À la validation, le prix d'achat de chaque produit est
  /// simplement AUGMENTÉ de sa part de frais (`+= frais/pièce`) — pas de
  /// moyenne pondérée, puisque aucune unité neuve ne se mélange aux
  /// anciennes.
  final bool costOnly;

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
    this.fees      = const [],
    this.costOnly  = false,
  });

  int get totalExpected  => items.fold(0, (s, i) => s + i.expectedQty);
  int get totalReceived  => items.fold(0, (s, i) => s + i.receivedQty);
  int get totalDamaged   => items.fold(0, (s, i) => s + i.damagedQty);
  int get totalDefective => items.fold(0, (s, i) => s + i.defectiveQty);
  int get totalConform   => items.fold(0, (s, i) => s + i.conformQty);
  bool get hasIssues     => items.any((i) => i.hasIssues);

  /// Somme des frais du lot. La RÉPARTITION, elle, vit dans
  /// `ArrivalCostingService` — source unique du calcul.
  double get feesTotal => fees.fold(0.0, (s, f) => s + f.amount);

  /// Valeur marchandise figée à la validation (Σ qté × coût de revient).
  /// `0` tant qu'aucun prix d'achat n'a été saisi sur les lignes.
  double get landedTotal =>
      items.fold(0.0, (s, i) => s + i.receivedQty * i.landedUnitCost);

  bool get hasCosting => items.any((i) => i.unitCost > 0) || feesTotal > 0;

  /// Nombre de pièces qui se partagent les frais.
  int get costingPieces => items.fold(0, (s, i) => s + i.costingQty);

  Reception copyWith({
    ReceptionStatus? status,
    List<ReceptionItem>? items,
    List<ReceptionFee>? fees,
    bool? costOnly,
  }) => Reception(
    id: id, shopId: shopId,
    purchaseOrderId: purchaseOrderId, supplierId: supplierId,
    status:    status ?? this.status,
    items:     items  ?? this.items,
    notes:     notes,
    createdBy: createdBy,
    createdAt: createdAt,
    fees:      fees   ?? this.fees,
    costOnly:  costOnly ?? this.costOnly,
  );

  // Schema versioning — cf. lib/core/storage/schema_migrator.dart.
  //   v1 → v2 : arrivage valorisé — `fees` (frais du lot) sur le bon,
  //             `unit_cost` / `landed_unit_cost` sur chaque ligne.
  //   v2 → v3 : `cost_only` — bon de frais seuls sur du stock déjà entré.
  static const int currentSchemaVersion = 3;
  static final SchemaMigrator _migrator = SchemaMigrator(
    currentVersion: currentSchemaVersion,
    steps: {
      // Les bons antérieurs n'ont aucune valorisation : lot sans frais,
      // lignes à coût nul. Purement additif, donc idempotent.
      1: (m) => m..putIfAbsent('fees', () => const <Map<String, dynamic>>[]),
      // Tout bon antérieur faisait entrer de la marchandise : jamais un
      // bon de frais seuls. Purement additif, donc idempotent.
      2: (m) => m..putIfAbsent('cost_only', () => false),
    },
  );

  Map<String, dynamic> toMap() => {
    'schema_version': currentSchemaVersion,
    'id': id, 'shop_id': shopId,
    'purchase_order_id': purchaseOrderId,
    'supplier_id': supplierId,
    'status': status.name,
    'items': items.map((i) => i.toMap()).toList(),
    'fees': fees.map((f) => f.toMap()).toList(),
    'cost_only': costOnly,
    'notes': notes, 'created_by': createdBy,
    'created_at': createdAt.toIso8601String(),
  };

  factory Reception.fromMap(Map<String, dynamic> rawM) {
    final m = _migrator.migrate(rawM);
    return Reception(
    id:              m['id'] as String,
    shopId:          m['shop_id'] as String,
    purchaseOrderId: m['purchase_order_id'] as String?,
    supplierId:      m['supplier_id'] as String?,
    status:          ReceptionStatusX.fromString(m['status'] as String?),
    items:           ((m['items'] as List?) ?? [])
        .map((e) => ReceptionItem.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList(),
    fees:            ((m['fees'] as List?) ?? [])
        .map((e) => ReceptionFee.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList(),
    costOnly:        m['cost_only'] as bool? ?? false,
    notes:           m['notes'] as String?,
    createdBy:       m['created_by'] as String?,
    createdAt:       DateTime.tryParse(m['created_at']?.toString() ?? '') ?? DateTime.now(),
    );
  }

  @override
  List<Object?> get props => [id, shopId, status, items, fees, costOnly];
}
