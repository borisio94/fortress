import '../../domain/entities/sale.dart';
import 'sale_item_model.dart';

class SaleModel {
  final String? id;
  final String  shopId;
  final List<SaleItemModel> items;
  final double  discountAmount;
  final double  taxRate;
  final List<Map<String, dynamic>> fees;
  final String  paymentMethod;
  final String? clientId;
  final String? clientName;
  final String? clientPhone;
  final String? notes;
  final DateTime createdAt;
  final DateTime? scheduledAt;
  final bool    syncedToCloud;
  final String  status;
  final String  source;
  final String? createdByUserId;

  // ── Champs livraison / e-commerce ──────────────────────────────────
  // Snapshot par commande : chaque vente garde EXACTEMENT les détails
  // de livraison utilisés lors de l'encaissement. Sans ces champs, le
  // restart Hive perdait tout (mode, partenaire, ville, agence, etc.) —
  // ce qui cassait notamment le filtre "Vue partenaire" de la page
  // Commandes (cf. orderToPartnerLocId qui consulte deliveryLocationId).
  final String? deliveryMode;          // pickup | in_house | partner | shipment
  final String? deliveryLocationId;
  final String? deliveryPersonName;
  final String? deliveryCity;
  final String? deliveryAddress;
  final String? shipmentCity;
  final String? shipmentAgency;
  final String? shipmentHandler;
  final String? cancellationReason;
  final String? rescheduleReason;

  // ── Suivi paiement (hotfix_065_orders_payment_tracking) ───────────
  /// Somme effectivement encaissée. Reflète l'acompte boutique +
  /// l'encaissement partenaire à la livraison.
  final double  amountPaid;
  /// 'unpaid' | 'partial' | 'paid' | 'refunded'.
  final String  paymentStatus;

  const SaleModel({
    this.id,
    required this.shopId,
    required this.items,
    this.discountAmount = 0,
    this.taxRate        = 0,
    this.fees           = const [],
    required this.paymentMethod,
    this.clientId,
    this.clientName,
    this.clientPhone,
    this.notes,
    required this.createdAt,
    this.scheduledAt,
    this.syncedToCloud = false,
    this.status = 'completed',
    this.source = 'pos',
    this.createdByUserId,
    this.deliveryMode,
    this.deliveryLocationId,
    this.deliveryPersonName,
    this.deliveryCity,
    this.deliveryAddress,
    this.shipmentCity,
    this.shipmentAgency,
    this.shipmentHandler,
    this.cancellationReason,
    this.rescheduleReason,
    this.amountPaid = 0,
    this.paymentStatus = 'unpaid',
  });

  factory SaleModel.fromMap(Map<String, dynamic> m) => SaleModel(
    id:             m['id'] as String?,
    shopId:         m['shop_id'] as String,
    items:          (m['items'] as List? ?? [])
        .map((i) => SaleItemModel.fromMap(Map<String, dynamic>.from(i))).toList(),
    discountAmount: (m['discount_amount'] as num?)?.toDouble() ?? 0,
    taxRate:        (m['tax_rate']        as num?)?.toDouble() ?? 0,
    fees:           ((m['fees'] as List?) ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList(),
    paymentMethod:  m['payment_method'] as String? ?? 'cash',
    clientId:       m['client_id']    as String?,
    clientName:     m['client_name']  as String?,
    clientPhone:    m['client_phone'] as String?,
    notes:          m['notes']        as String?,
    createdAt:      _parseDate(m['created_at']) ?? DateTime.now(),
    scheduledAt:    _parseDate(m['scheduled_at']),
    syncedToCloud:  m['synced_to_cloud'] as bool? ?? false,
    status:         m['status'] as String? ?? 'completed',
    source:         m['source'] as String? ?? 'pos',
    createdByUserId:    m['created_by_user_id'] as String?,
    deliveryMode:       m['delivery_mode']         as String?,
    deliveryLocationId: m['delivery_location_id'] as String?,
    deliveryPersonName: m['delivery_person_name'] as String?,
    deliveryCity:       m['delivery_city']    as String?,
    deliveryAddress:    m['delivery_address'] as String?,
    shipmentCity:       m['shipment_city']    as String?,
    shipmentAgency:     m['shipment_agency']  as String?,
    shipmentHandler:    m['shipment_handler'] as String?,
    cancellationReason: m['cancellation_reason'] as String?,
    rescheduleReason:   m['reschedule_reason']   as String?,
    amountPaid:         (m['amount_paid'] as num?)?.toDouble() ?? 0,
    paymentStatus:      m['payment_status'] as String? ?? 'unpaid',
  );

  static DateTime? _parseDate(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    if (v is String) return DateTime.tryParse(v);
    return null;
  }

  Map<String, dynamic> toMap() => {
    'id':              id,
    'shop_id':         shopId,
    'items':           items.map((i) => i.toMap()).toList(),
    'discount_amount': discountAmount,
    'tax_rate':        taxRate,
    'fees':            fees,
    'payment_method':  paymentMethod,
    'client_id':       clientId,
    'client_name':     clientName,
    'client_phone':    clientPhone,
    'notes':           notes,
    'created_at':      createdAt.toIso8601String(),
    'scheduled_at':    scheduledAt?.toIso8601String(),
    'synced_to_cloud': syncedToCloud,
    'status':          status,
    'source':          source,
    'created_by_user_id': createdByUserId,
    'delivery_mode':         deliveryMode,
    'delivery_location_id':  deliveryLocationId,
    'delivery_person_name':  deliveryPersonName,
    'delivery_city':         deliveryCity,
    'delivery_address':      deliveryAddress,
    'shipment_city':         shipmentCity,
    'shipment_agency':       shipmentAgency,
    'shipment_handler':      shipmentHandler,
    'cancellation_reason':   cancellationReason,
    'reschedule_reason':     rescheduleReason,
    'amount_paid':           amountPaid,
    'payment_status':        paymentStatus,
  };

  factory SaleModel.fromEntity(Sale s) => SaleModel(
    id:             s.id,
    shopId:         s.shopId,
    items:          s.items.map(SaleItemModel.fromEntity).toList(),
    discountAmount: s.discountAmount,
    taxRate:        s.taxRate,
    fees:           s.fees,
    paymentMethod:  s.paymentMethod.name,
    clientId:       s.clientId,
    clientName:     s.clientName,
    clientPhone:    s.clientPhone,
    notes:          s.notes,
    createdAt:      s.createdAt,
    scheduledAt:    s.scheduledAt,
    syncedToCloud:  s.syncedToCloud,
    status:         s.status.name,
    source:         s.source,
    createdByUserId:    s.createdByUserId,
    deliveryMode:       s.deliveryMode?.key,    // utilise l'extension DeliveryModeX.key
    deliveryLocationId: s.deliveryLocationId,
    deliveryPersonName: s.deliveryPersonName,
    deliveryCity:       s.deliveryCity,
    deliveryAddress:    s.deliveryAddress,
    shipmentCity:       s.shipmentCity,
    shipmentAgency:     s.shipmentAgency,
    shipmentHandler:    s.shipmentHandler,
    cancellationReason: s.cancellationReason,
    rescheduleReason:   s.rescheduleReason,
    amountPaid:         s.amountPaid,
    paymentStatus:      s.paymentStatus.key,
  );

  Sale toEntity() => Sale(
    id:             id,
    shopId:         shopId,
    items:          items.map((i) => i.toEntity()).toList(),
    discountAmount: discountAmount,
    taxRate:        taxRate,
    fees:           fees,
    paymentMethod:  PaymentMethod.values.firstWhere(
        (m) => m.name == paymentMethod, orElse: () => PaymentMethod.cash),
    clientId:       clientId,
    clientName:     clientName,
    clientPhone:    clientPhone,
    notes:          notes,
    createdAt:      createdAt,
    scheduledAt:    scheduledAt,
    syncedToCloud:  syncedToCloud,
    status:         SaleStatus.values.firstWhere(
        (s) => s.name == status, orElse: () => SaleStatus.completed),
    source:         source,
    createdByUserId:    createdByUserId,
    deliveryMode:       DeliveryModeX.fromKey(deliveryMode),
    deliveryLocationId: deliveryLocationId,
    deliveryPersonName: deliveryPersonName,
    deliveryCity:       deliveryCity,
    deliveryAddress:    deliveryAddress,
    shipmentCity:       shipmentCity,
    shipmentAgency:     shipmentAgency,
    shipmentHandler:    shipmentHandler,
    cancellationReason: cancellationReason,
    rescheduleReason:   rescheduleReason,
    amountPaid:         amountPaid,
    paymentStatus:      PaymentStatusX.fromKey(paymentStatus),
  );
}
