import 'package:equatable/equatable.dart';
import '../../domain/usecases/add_product_usecase.dart';
import '../../domain/entities/product.dart';

abstract class InventaireEvent extends Equatable {
  @override List<Object?> get props => [];
}
class LoadProducts extends InventaireEvent {
  final String shopId;
  LoadProducts(this.shopId);
  @override List<Object> get props => [shopId];
}
class AddProduct extends InventaireEvent {
  final AddProductParams params;
  AddProduct(this.params);
  @override List<Object> get props => [params];
}
class UpdateProduct extends InventaireEvent {
  final Product product;
  UpdateProduct(this.product);
  @override List<Object> get props => [product];
}
class DeleteProduct extends InventaireEvent {
  final String productId;
  final String shopId;
  DeleteProduct(this.productId, this.shopId);
  @override List<Object> get props => [productId, shopId];
}
class UpdateStock extends InventaireEvent {
  final String productId;
  final String shopId;
  final int newStock;
  UpdateStock(this.productId, this.shopId, this.newStock);
  @override List<Object> get props => [productId, shopId, newStock];
}
class SearchProducts extends InventaireEvent {
  final String query;
  SearchProducts(this.query);
  @override List<Object> get props => [query];
}
class ScanBarcode extends InventaireEvent {
  final String barcode;
  final String shopId;
  ScanBarcode(this.barcode, this.shopId);
  @override List<Object> get props => [barcode, shopId];
}
