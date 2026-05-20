import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/database/app_database.dart';
import '../models/product_model.dart';

abstract class ProductLocalDataSource {
  Future<List<ProductModel>> getCachedProducts(String shopId);
  Future<void> cacheProducts(String shopId, List<ProductModel> products);
  Future<void> saveProduct(ProductModel product);
  Future<void> deleteProduct(String productId, String shopId, {
    required String reason,
    required String userId,
  });
  Future<void> updateStock(String productId, String shopId, int newStock);
  Future<ProductModel?> getByBarcode(String barcode, String shopId);
}

class ProductLocalDataSourceImpl implements ProductLocalDataSource {

  @override
  Future<List<ProductModel>> getCachedProducts(String shopId) async {
    final products = LocalStorageService.getProductsForShop(shopId);
    return products.map(ProductModel.fromEntity).toList();
  }

  @override
  Future<void> cacheProducts(String shopId, List<ProductModel> products) async {
    for (final p in products) {
      await LocalStorageService.saveProduct(p.toEntity());
    }
  }

  @override
  Future<void> saveProduct(ProductModel product) async {
    await LocalStorageService.saveProduct(product.toEntity());
  }

  @override
  Future<void> deleteProduct(String productId, String shopId, {
    required String reason,
    required String userId,
  }) async {
    // Le LocalStorageService.deleteProduct hard-delete reste interne au
    // service (utilisé par le purge boutique). Le flow soft-delete public
    // passe par `AppDatabase.deleteProduct` qui marque Hive sans retirer
    // la ligne — puis push la RPC `delete_product`. On délègue donc ici
    // au orchestre AppDatabase plutôt que d'appeler LocalStorageService
    // directement (qui ferait un hard-delete contraire à la spec).
    await AppDatabase.deleteProduct(productId, reason: reason, userId: userId);
  }

  @override
  Future<void> updateStock(String productId, String shopId, int newStock) async {
    final p = LocalStorageService.getProduct(productId);
    if (p != null) {
      await LocalStorageService.saveProduct(p.copyWith(stockQty: newStock));
    }
  }

  @override
  Future<ProductModel?> getByBarcode(String barcode, String shopId) async {
    final products = LocalStorageService.getProductsForShop(shopId);
    final result = products.where((p) => p.barcode == barcode);
    return result.isEmpty ? null : ProductModel.fromEntity(result.first);
  }
}
