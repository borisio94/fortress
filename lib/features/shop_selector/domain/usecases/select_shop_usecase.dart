import 'get_my_shops_usecase.dart';

class SelectShopUseCase {
  final ShopSelectorRepository repository;
  const SelectShopUseCase(this.repository);
  Future<void> call(String shopId) => repository.selectShop(shopId);
}
