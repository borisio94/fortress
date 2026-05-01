import '../../../../core/database/app_database.dart';
import '../../domain/usecases/add_product_usecase.dart';
import '../models/product_model.dart';

abstract class ProductRemoteDataSource {
  Future<List<ProductModel>> getProducts(String shopId);
  Future<ProductModel> addProduct(AddProductParams params, String shopId);
  Future<ProductModel> updateProduct(ProductModel product, String shopId);
  Future<void> deleteProduct(String productId, String shopId);
  Future<void> updateStock(String productId, String shopId, int newStock);
}

/// Implémentation via AppDatabase (Supabase + Hive offline-first).
/// La sync réelle est gérée par [AppDatabase.syncProducts] et [AppDatabase.saveProduct].
class ProductRemoteDataSourceImpl implements ProductRemoteDataSource {
  const ProductRemoteDataSourceImpl();

  @override
  Future<List<ProductModel>> getProducts(String shopId) async {
    await AppDatabase.syncProducts(shopId);
    return AppDatabase.getProductsForShop(shopId)
        .map(ProductModel.fromEntity)
        .toList();
  }

  @override
  Future<ProductModel> addProduct(AddProductParams params, String shopId) async {
    final product = params.toProduct(shopId);
    await AppDatabase.saveProduct(product);
    return ProductModel.fromEntity(product);
  }

  @override
  Future<ProductModel> updateProduct(ProductModel product, String shopId) async {
    await AppDatabase.saveProduct(product.toEntity());
    return product;
  }

  @override
  Future<void> deleteProduct(String productId, String shopId) =>
      AppDatabase.deleteProduct(productId);

  @override
  Future<void> updateStock(String productId, String shopId, int newStock) async {
    final products = AppDatabase.getProductsForShop(shopId);
    final product  = products.where((p) => p.id == productId).firstOrNull;
    if (product == null) return;
    await AppDatabase.saveProduct(product.copyWith(stockQty: newStock));
  }
}