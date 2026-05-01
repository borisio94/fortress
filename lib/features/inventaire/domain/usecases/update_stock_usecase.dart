import '../repositories/product_repository.dart';

class UpdateStockUseCase {
  final ProductRepository repository;
  const UpdateStockUseCase(this.repository);
  Future<void> call(String productId, String shopId, int newStock) =>
      repository.updateStock(productId, shopId, newStock);
}
