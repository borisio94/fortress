import '../../../../core/error/exceptions.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../models/product_model.dart';

abstract class ProductLocalDataSource {
  Future<List<ProductModel>> getCachedProducts(String shopId);
  Future<void> cacheProducts(String shopId, List<ProductModel> products);
  Future<void> saveProduct(ProductModel product);
  Future<void> deleteProduct(String productId, String shopId);
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
  Future<void> deleteProduct(String productId, String shopId) async {
    await LocalStorageService.deleteProduct(productId);
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
