import '../entities/product.dart';
import '../repositories/product_repository.dart';

class CheckLowStockUseCase {
  final ProductRepository repository;
  const CheckLowStockUseCase(this.repository);
  List<Product> call(String shopId) =>
      repository.getProducts(shopId).where((p) => p.isLowStock).toList();
}
