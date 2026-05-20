import '../entities/product.dart';
import '../usecases/add_product_usecase.dart';

abstract class ProductRepository {
  List<Product>  getProducts(String shopId);
  Future<Product> addProduct(AddProductParams params);
  Future<Product> updateProduct(Product product);
  /// hotfix_085 — soft-delete (reason ≥ 10, userId requis). L'impl
  /// délègue à `AppDatabase.deleteProduct` qui marque Hive + pousse la RPC
  /// `delete_product`. Lève `ProductNotDeletableException` si stock ou
  /// commandes ouvertes bloquent.
  Future<void>   deleteProduct(String productId, String shopId, {
    required String reason,
    required String userId,
  });
  Future<void>   updateStock(String productId, String shopId, int newStock);
  Future<void>   syncProducts(String shopId);
}
