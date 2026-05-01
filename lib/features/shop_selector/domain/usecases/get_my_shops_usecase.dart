import '../entities/shop_summary.dart';
import '../repositories/shop_selector_repository.dart';

abstract class ShopSelectorRepository {
  Future<List<ShopSummary>> getMyShops();
  Future<ShopSummary>       createShop(Map<String, dynamic> data);
  Future<ShopSummary>       updateShop(String shopId, Map<String, dynamic> data);
  Future<void>              selectShop(String shopId);
}

class GetMyShopsUseCase {
  final ShopSelectorRepository repository;
  const GetMyShopsUseCase(this.repository);
  Future<List<ShopSummary>> call() => repository.getMyShops();
}
