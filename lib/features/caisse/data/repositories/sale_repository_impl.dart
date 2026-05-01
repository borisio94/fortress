import '../../domain/entities/sale.dart';
import '../../domain/repositories/sale_repository.dart';
import 'sale_local_datasource.dart';
import '../../../../core/database/app_database.dart';

class SaleRepositoryImpl implements SaleRepository {
  final SaleLocalDatasource local;
  const SaleRepositoryImpl({required this.local});

  @override
  Future<Sale> createSale(Sale sale) async {
    // Sauvegarder localement (offline-first)
    await local.saveSaleOffline(sale);
    // Envoyer en background vers Supabase
    await local.enqueueOfflineAction({
      'table': 'sales',
      'op':    'upsert',
      'data':  _saleToMap(sale),
    });
    await local.clearCart();
    return sale;
  }

  @override
  Future<List<Sale>> getSalesHistory(String shopId,
      {DateTime? from, DateTime? to}) async {
    var sales = await local.getPendingSales(shopId);
    if (from != null) sales = sales.where((s) => s.createdAt.isAfter(from)).toList();
    if (to   != null) sales = sales.where((s) => s.createdAt.isBefore(to)).toList();
    return sales;
  }

  @override
  Future<Sale> refundSale(String saleId, String shopId) async {
    final sales = await local.getPendingSales(shopId);
    final sale  = sales.firstWhere((s) => s.id == saleId,
        orElse: () => throw Exception('Vente introuvable: $saleId'));
    final refund = sale.copyWith(status: SaleStatus.refunded);
    await local.saveSaleOffline(refund);
    await local.enqueueOfflineAction({
      'table': 'sales',
      'op':    'upsert',
      'data':  _saleToMap(refund),
    });
    return refund;
  }

  @override
  Future<List<Sale>> getPendingOfflineSales(String shopId) async {
    final sales = await local.getPendingSales(shopId);
    return sales.where((s) => s.status == SaleStatus.scheduled).toList();
  }

  @override
  Future<int> syncOfflineSales(String shopId) async {
    await AppDatabase.flushOfflineQueue();
    return AppDatabase.pendingOpsCount;
  }

  // ── helper ────────────────────────────────────────────────────────────────
  Map<String, dynamic> _saleToMap(Sale s) => {
    'id':             s.id,
    'shop_id':        s.shopId,
    'discount_amount':s.discountAmount,
    'payment_method': s.paymentMethod.name,
    'status':         s.status.name,
    'client_id':      s.clientId,
    'client_phone':   s.clientPhone,
    'created_at':     s.createdAt.toIso8601String(),
    'synced_to_cloud':s.syncedToCloud,
    'fees':           s.fees,
    'items':          s.items.map((i) => {
      'product_id':   i.productId,
      'product_name': i.productName,
      'unit_price':   i.unitPrice,
      'price_buy':    i.priceBuy,    // ← essentiel pour calcul bénéfice fiable
      'custom_price': i.customPrice,
      'quantity':     i.quantity,
      'discount':     i.discount,
      'variant_name': i.variantName,
    }).toList(),
  };
}