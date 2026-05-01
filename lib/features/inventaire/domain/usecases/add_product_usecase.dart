import 'package:equatable/equatable.dart';
import '../entities/product.dart';
import '../repositories/product_repository.dart';

class AddProductUseCase {
  final ProductRepository repository;
  const AddProductUseCase(this.repository);
  Future<Product> call(AddProductParams params) => repository.addProduct(params);
}

class AddProductParams extends Equatable {
  final String  shopId, name;
  final double  priceBuy, priceSellPos;
  final int     stockQty;
  final String? categoryId, brand, sku, description;
  const AddProductParams({
    required this.shopId, required this.name,
    this.priceBuy = 0, this.priceSellPos = 0, this.stockQty = 0,
    this.categoryId, this.brand, this.sku, this.description,
  });

  Product toProduct(String shopId) => Product(
    id:          'prod_${DateTime.now().millisecondsSinceEpoch}',
    storeId:     shopId,
    name:        name,
    priceBuy:    priceBuy,
    priceSellPos:priceSellPos,
    stockQty:    stockQty,
    categoryId:  categoryId,
    brand:       brand,
    sku:         sku,
    description: description,
  );

  @override List<Object?> get props => [shopId, name];
}
