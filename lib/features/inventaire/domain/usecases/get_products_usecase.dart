import '../entities/product.dart';
import '../repositories/product_repository.dart';

class GetProductsUseCase {
  final ProductRepository repository;
  const GetProductsUseCase(this.repository);
  List<Product> call(String shopId) => repository.getProducts(shopId);
}
