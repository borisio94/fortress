import '../entities/sale.dart';
import '../repositories/sale_repository.dart';

class ProcessPaymentUseCase {
  final SaleRepository repository;
  const ProcessPaymentUseCase(this.repository);
  Future<Sale> call(Sale sale) => repository.createSale(sale);
}
