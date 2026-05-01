import 'package:equatable/equatable.dart';
import '../../domain/entities/product.dart';

abstract class InventaireState extends Equatable {
  @override List<Object?> get props => [];
}
class InventaireInitial extends InventaireState {}
class InventaireLoading extends InventaireState {}
class InventaireLoaded extends InventaireState {
  final List<Product> products;
  final List<Product> filtered;
  final String query;
  InventaireLoaded({required this.products, List<Product>? filtered, this.query = ''})
      : filtered = filtered ?? products;
  InventaireLoaded copyWith({List<Product>? products, List<Product>? filtered, String? query}) =>
      InventaireLoaded(products: products ?? this.products, filtered: filtered ?? this.filtered, query: query ?? this.query);
  @override List<Object> get props => [products, filtered, query];
}
class InventaireError extends InventaireState {
  final String message;
  InventaireError(this.message);
  @override List<Object> get props => [message];
}
class ProductFound extends InventaireState {
  final Product product;
  ProductFound(this.product);
  @override List<Object> get props => [product];
}
