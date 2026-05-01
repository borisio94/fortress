import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../../core/services/activity_log_service.dart';
import '../../domain/entities/product.dart';
import '../../domain/usecases/get_products_usecase.dart';
import '../../domain/usecases/add_product_usecase.dart';
import '../../domain/usecases/update_stock_usecase.dart';
import '../../domain/repositories/product_repository.dart';
import 'inventaire_event.dart';
import 'inventaire_state.dart';

class InventaireBloc extends Bloc<InventaireEvent, InventaireState> {
  final GetProductsUseCase  getProducts;
  final AddProductUseCase   addProduct;
  final UpdateStockUseCase  updateStock;
  final ProductRepository   repository;

  InventaireBloc({
    required this.getProducts,
    required this.addProduct,
    required this.updateStock,
    required this.repository,
  }) : super(InventaireInitial()) {
    on<LoadProducts>(_onLoad);
    on<AddProduct>(_onAdd);
    on<UpdateProduct>(_onUpdateProduct);
    on<UpdateStock>(_onUpdateStock);
    on<DeleteProduct>(_onDelete);
    on<SearchProducts>(_onSearch);
    on<ScanBarcode>(_onScan);
  }

  Future<void> _onLoad(LoadProducts event, Emitter<InventaireState> emit) async {
    emit(InventaireLoading());
    try {
      // getProducts est synchrone — lit depuis Hive
      final products = getProducts(event.shopId);
      emit(InventaireLoaded(products: products));
      // Sync silencieuse en arrière-plan
      repository.syncProducts(event.shopId);
    } catch (e) {
      emit(InventaireError(e.toString().replaceAll('Exception: ', '')));
    }
  }

  Future<void> _onAdd(AddProduct event, Emitter<InventaireState> emit) async {
    try {
      final product = await addProduct(event.params);
      await ActivityLogService.log(
        action:      'product_created',
        targetType:  'product',
        targetId:    product.id,
        targetLabel: product.name,
        shopId:      product.storeId,
        details:     {
          if ((product.sku ?? '').isNotEmpty) 'sku':       product.sku,
          if ((product.categoryId ?? '').isNotEmpty)
            'category': product.categoryId,
          if ((product.brand ?? '').isNotEmpty) 'brand':   product.brand,
          'price':    product.priceSellPos,
          'stock':    product.totalStock,
          if (product.variants.isNotEmpty)
            'variant_count': product.variants.length,
        },
      );
      if (state is InventaireLoaded) {
        final current = (state as InventaireLoaded).products;
        emit(InventaireLoaded(products: [...current, product]));
      }
    } catch (e) {
      emit(InventaireError(e.toString().replaceAll('Exception: ', '')));
    }
  }

  Future<void> _onUpdateProduct(UpdateProduct event, Emitter<InventaireState> emit) async {
    try {
      final updated = await repository.updateProduct(event.product);
      await ActivityLogService.log(
        action:      'product_updated',
        targetType:  'product',
        targetId:    updated.id,
        targetLabel: updated.name,
        shopId:      updated.storeId,
        details:     {
          if ((updated.sku ?? '').isNotEmpty) 'sku':       updated.sku,
          if ((updated.categoryId ?? '').isNotEmpty)
            'category': updated.categoryId,
          if ((updated.brand ?? '').isNotEmpty) 'brand':   updated.brand,
          'price':    updated.priceSellPos,
          'stock':    updated.totalStock,
          if (updated.variants.isNotEmpty)
            'variant_count': updated.variants.length,
        },
      );
      if (state is InventaireLoaded) {
        final products = (state as InventaireLoaded).products
            .map((p) => p.id == updated.id ? updated : p)
            .toList();
        emit(InventaireLoaded(products: products));
      }
    } catch (e) {
      emit(InventaireError(e.toString().replaceAll('Exception: ', '')));
    }
  }

  Future<void> _onUpdateStock(UpdateStock event, Emitter<InventaireState> emit) async {
    try {
      // Capturer l'état avant changement pour le delta loggué
      Product? before;
      if (state is InventaireLoaded) {
        before = (state as InventaireLoaded).products
            .where((p) => p.id == event.productId)
            .firstOrNull;
      }
      await updateStock(event.productId, event.shopId, event.newStock);
      await ActivityLogService.log(
        action:      'stock_updated',
        targetType:  'product',
        targetId:    event.productId,
        targetLabel: before?.name,
        shopId:      event.shopId,
        details: {
          'before': before?.stockQty,
          'after':  event.newStock,
          'delta':  before != null ? event.newStock - before.stockQty : null,
        },
      );
      if (state is InventaireLoaded) {
        final products = (state as InventaireLoaded).products
            .map((p) => p.id == event.productId
            ? p.copyWith(stockQty: event.newStock) : p)
            .toList();
        emit(InventaireLoaded(products: products));
      }
    } catch (e) {
      emit(InventaireError(e.toString().replaceAll('Exception: ', '')));
    }
  }

  Future<void> _onDelete(DeleteProduct event, Emitter<InventaireState> emit) async {
    try {
      Product? deleted;
      if (state is InventaireLoaded) {
        deleted = (state as InventaireLoaded).products
            .where((p) => p.id == event.productId)
            .firstOrNull;
      }
      await repository.deleteProduct(event.productId, event.shopId);
      await ActivityLogService.log(
        action:      'product_deleted',
        targetType:  'product',
        targetId:    event.productId,
        targetLabel: deleted?.name,
        shopId:      event.shopId,
        details: deleted == null ? null : {
          if ((deleted.sku ?? '').isNotEmpty) 'sku':       deleted.sku,
          if ((deleted.categoryId ?? '').isNotEmpty)
            'category': deleted.categoryId,
          if ((deleted.brand ?? '').isNotEmpty) 'brand':   deleted.brand,
          'stock_before': deleted.totalStock,
        },
      );
      if (state is InventaireLoaded) {
        final products = (state as InventaireLoaded).products
            .where((p) => p.id != event.productId)
            .toList();
        emit(InventaireLoaded(products: products));
      }
    } catch (e) {
      emit(InventaireError(e.toString().replaceAll('Exception: ', '')));
    }
  }

  void _onSearch(SearchProducts event, Emitter<InventaireState> emit) {
    if (state is! InventaireLoaded) return;
    final s = state as InventaireLoaded;
    final q = event.query.toLowerCase();
    final filtered = q.isEmpty
        ? s.products
        : s.products.where((p) =>
    p.name.toLowerCase().contains(q) ||
        (p.barcode?.contains(q) ?? false) ||
        (p.sku?.toLowerCase().contains(q) ?? false) ||
        (p.categoryId?.toLowerCase().contains(q) ?? false)).toList();
    emit(s.copyWith(filtered: filtered, query: event.query));
  }

  Future<void> _onScan(ScanBarcode event, Emitter<InventaireState> emit) async {
    // Recherche locale dans Hive par code-barres
    final products = getProducts(event.shopId);
    final found = products
        .where((p) => p.barcode == event.barcode)
        .firstOrNull;
    if (found != null) {
      emit(ProductFound(found));
    } else {
      emit(InventaireError('Produit non trouvé: ${event.barcode}'));
    }
  }
}