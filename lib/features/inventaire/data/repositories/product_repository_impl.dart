import '../../domain/entities/product.dart';
import '../../domain/repositories/product_repository.dart';
import '../../domain/usecases/add_product_usecase.dart';
import '../models/product_model.dart';
import 'product_local_datasource.dart';
import 'product_remote_datasource.dart';
import '../../../../core/database/app_database.dart';

class ProductRepositoryImpl implements ProductRepository {
  final ProductRemoteDataSource remote;
  final ProductLocalDataSource  local;
  ProductRepositoryImpl({required this.remote, required this.local});

  @override
  List<Product> getProducts(String shopId) =>
      AppDatabase.getProductsForShop(shopId);

  @override
  Future<Product> addProduct(AddProductParams params) async {
    final p = params.toProduct(params.shopId);
    await AppDatabase.saveProduct(p);
    return p;
  }

  @override
  Future<Product> updateProduct(Product product) async {
    await AppDatabase.saveProduct(product);
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

  @override
  Future<void> syncProducts(String shopId) =>
      AppDatabase.syncProducts(shopId);
}