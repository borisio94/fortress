import 'package:equatable/equatable.dart';

/// État d'un transfert entre deux [StockLocation].
/// - [draft]     : créé, pas encore envoyé. Modifiable, supprimable.
/// - [shipped]   : expédié — les quantités sont décrémentées de la source
///                 et placées en "en transit" jusqu'à réception.
/// - [received]  : réceptionné — les quantités arrivent dans la destination.
///                 Opération finalisée, inaltérable.
/// - [cancelled] : annulé avant expédition. Aucun impact sur les stocks.
enum StockTransferStatus { draft, shipped, received, cancelled }

extension StockTransferStatusX on StockTransferStatus {
  String get key => switch (this) {
    StockTransferStatus.draft     => 'draft',
    StockTransferStatus.shipped   => 'shipped',
    StockTransferStatus.received  => 'received',
    StockTransferStatus.cancelled => 'cancelled',
  };

  String get labelFr => switch (this) {
    StockTransferStatus.draft     => 'Brouillon',
    StockTransferStatus.shipped   => 'Expédié',
    StockTransferStatus.received  => 'Reçu',
    StockTransferStatus.cancelled => 'Annulé',
  };

  static StockTransferStatus fromKey(String? k) => switch (k) {
    'shipped'   => StockTransferStatus.shipped,
    'received'  => StockTransferStatus.received,
    'cancelled' => StockTransferStatus.cancelled,
    _           => StockTransferStatus.draft,
  };
}

/// Ligne d'un transfert : une variante + la quantité envoyée.
class StockTransferLine extends Equatable {
  final String variantId;
  final int quantity;
  final String? productName;   // dénormalisé pour affichage historique
  final String? variantName;   // idem

  const StockTransferLine({
    required this.variantId,
    required this.quantity,
    this.productName,
    this.variantName,
  });

  Map<String, dynamic> toMap() => {
    'variant_id': variantId,
    'quantity': quantity,
    'product_name': productName,
    'variant_name': variantName,
  };

  factory StockTransferLine.fromMap(Map<String, dynamic> m) =>
      StockTransferLine(
        variantId:   m['variant_id'] as String? ?? '',
        quantity:    (m['quantity'] as num?)?.toInt() ?? 0,
        productName: m['product_name'] as String?,
        variantName: m['variant_name'] as String?,
      );

  @override
  List<Object?> get props => [variantId, quantity];
}

/// Transfert de stock entre deux emplacements.
class StockTransfer extends Equatable {
  final String id;
  final String ownerId;
  final String fromLocationId;
  final String toLocationId;
  final StockTransferStatus status;
  final List<StockTransferLine> lines;
  final String? notes;
  final String? createdBy;
  final DateTime createdAt;
  final DateTime? shippedAt;
  final DateTime? receivedAt;
  final DateTime? cancelledAt;

  const StockTransfer({
    required this.id,
    required this.ownerId,
    required this.fromLocationId,
    required this.toLocationId,
    this.status = StockTransferStatus.draft,
    this.lines = const [],
    this.notes,
    this.createdBy,
    required this.createdAt,
    this.shippedAt,
    this.receivedAt,
    this.cancelledAt,
  });

  StockTransfer copyWith({
    StockTransferStatus? status,
    List<StockTransferLine>? lines,
    String? notes,
    DateTime? shippedAt,
    DateTime? receivedAt,
    DateTime? cancelledAt,
  }) => StockTransfer(
    id:             id,
    ownerId:        ownerId,
    fromLocationId: fromLocationId,
    toLocationId:   toLocationId,
    status:         status ?? this.status,
    lines:          lines ?? this.lines,
    notes:          notes ?? this.notes,
    createdBy:      createdBy,
    createdAt:      createdAt,
    shippedAt:      shippedAt ?? this.shippedAt,
    receivedAt:     receivedAt ?? this.receivedAt,
    cancelledAt:    cancelledAt ?? this.cancelledAt,
  );

  int get totalQuantity =>
      lines.fold(0, (s, l) => s + l.quantity);

  Map<String, dynamic> toMap() => {
    'id': id,
    'owner_id': ownerId,
    'from_location_id': fromLocationId,
    'to_location_id':   toLocationId,
    'status': status.key,
    'lines': lines.map((l) => l.toMap()).toList(),
    'notes': notes,
    'created_by': createdBy,
    'created_at': createdAt.toIso8601String(),
    'shipped_at':   shippedAt?.toIso8601String(),
    'received_at':  receivedAt?.toIso8601String(),
    'cancelled_at': cancelledAt?.toIso8601String(),
  };

  factory StockTransfer.fromMap(Map<String, dynamic> m) {
    final rawLines = m['lines'] as List? ?? const [];
    return StockTransfer(
      id:             m['id'] as String,
      ownerId:        m['owner_id'] as String? ?? '',
      fromLocationId: m['from_location_id'] as String? ?? '',
      toLocationId:   m['to_location_id']   as String? ?? '',
      status:         StockTransferStatusX.fromKey(m['status'] as String?),
      lines:          rawLines
          .map((e) => StockTransferLine.fromMap(Map<String, dynamic>.from(e as Map)))
          .toList(),
      notes:          m['notes'] as String?,
      createdBy:      m['created_by'] as String?,
      createdAt:      DateTime.tryParse(m['created_at']?.toString() ?? '')
                      ?? DateTime.now(),
      shippedAt:      m['shipped_at'] != null
                      ? DateTime.tryParse(m['shipped_at'].toString()) : null,
      receivedAt:     m['received_at'] != null
                      ? DateTime.tryParse(m['received_at'].toString()) : null,
      cancelledAt:    m['cancelled_at'] != null
                      ? DateTime.tryParse(m['cancelled_at'].toString()) : null,
    );
  }

  @override
  List<Object?> get props =>
      [id, ownerId, fromLocationId, toLocationId, status, lines];
}
