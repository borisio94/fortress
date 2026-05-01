import '../../domain/entities/sale.dart';
import 'sale_item_model.dart';

class SaleModel {
  final String? id;
  final String  shopId;
  final List<SaleItemModel> items;
  final double  discountAmount;
  final String  paymentMethod;
  final String? clientId;
  final String? clientPhone;
  final DateTime createdAt;
  final bool    syncedToCloud;
  final String  status;

  const SaleModel({
    this.id,
    required this.shopId,
    required this.items,
    this.discountAmount = 0,
    required this.paymentMethod,
    this.clientId,
    this.clientPhone,
    required this.createdAt,
    this.syncedToCloud = false,
    this.status = 'completed',
  });

  factory SaleModel.fromMap(Map<String, dynamic> m) => SaleModel(
    id:             m['id'] as String?,
    shopId:         m['shop_id'] as String,
    items:          (m['items'] as List? ?? [])
        .map((i) => SaleItemModel.fromMap(Map<String, dynamic>.from(i))).toList(),
    discountAmount: (m['discount_amount'] as num?)?.toDouble() ?? 0,
    paymentMethod:  m['payment_method'] as String? ?? 'cash',
    clientId:       m['client_id'] as String?,
    clientPhone:    m['client_phone'] as String?,
    createdAt:      m['created_at'] is String
        ? DateTime.parse(m['created_at'] as String)
        : (m['created_at'] as DateTime? ?? DateTime.now()),
    syncedToCloud:  m['synced_to_cloud'] as bool? ?? false,
    status:         m['status'] as String? ?? 'completed',
  );

  Map<String, dynamic> toMap() => {
    'id':             id,
    'shop_id':        shopId,
    'items':          items.map((i) => i.toMap()).toList(),
    'discount_amount':discountAmount,
    'payment_method': paymentMethod,
    'client_id':      clientId,
    'client_phone':   clientPhone,
    'created_at':     createdAt.toIso8601String(),
    'synced_to_cloud':syncedToCloud,
    'status':         status,
  };

  factory SaleModel.fromEntity(Sale s) => SaleModel(
    id:             s.id,
    shopId:         s.shopId,
    items:          s.items.map(SaleItemModel.fromEntity).toList(),
    discountAmount: s.discountAmount,
    paymentMethod:  s.paymentMethod.name,
    clientId:       s.clientId,
    clientPhone:    s.clientPhone,
    createdAt:      s.createdAt,
    syncedToCloud:  s.syncedToCloud,
    status:         s.status.name,
  );

  Sale toEntity() => Sale(
    id:             id,
    shopId:         shopId,
    items:          items.map((i) => i.toEntity()).toList(),
    discountAmount: discountAmount,
    paymentMethod:  PaymentMethod.values.firstWhere(
        (m) => m.name == paymentMethod, orElse: () => PaymentMethod.cash),
    clientId:       clientId,
    clientPhone:    clientPhone,
    createdAt:      createdAt,
    syncedToCloud:  syncedToCloud,
    status:         SaleStatus.values.firstWhere(
        (s) => s.name == status, orElse: () => SaleStatus.completed),
  );
}
