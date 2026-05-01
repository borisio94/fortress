import '../entities/product.dart';
import '../usecases/add_product_usecase.dart';

abstract class ProductRepository {
  List<Product>  getProducts(String shopId);
  Future<Product> addProduct(AddProductParams params);
  Future<Product> updateProduct(Product product);
  Future<void>   deleteProduct(String productId, String shopId);
  Future<void>   updateStock(String productId, String shopId, int newStock);
  Future<void>   syncProducts(String shopId);
}
