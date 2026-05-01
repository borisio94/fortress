import '../entities/sale.dart';
import '../repositories/sale_repository.dart';

class CreateSaleUseCase {
  final SaleRepository repository;
  const CreateSaleUseCase(this.repository);
  Future<Sale> call(Sale sale) => repository.createSale(sale);
}
