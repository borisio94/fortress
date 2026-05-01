import '../entities/sale.dart';

abstract class SaleRepository {
  Future<Sale>       createSale(Sale sale);
  Future<List<Sale>> getSalesHistory(String shopId, {DateTime? from, DateTime? to});
  Future<Sale>       refundSale(String saleId, String shopId);
  Future<List<Sale>> getPendingOfflineSales(String shopId);
  Future<int>        syncOfflineSales(String shopId);
}
