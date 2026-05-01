import 'package:flutter/foundation.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../domain/entities/shop_summary.dart';
import '../../domain/usecases/get_my_shops_usecase.dart';

class ShopSelectorRepositoryImpl implements ShopSelectorRepository {

  @override
  Future<List<ShopSummary>> getMyShops() async {
    final userId = LocalStorageService.getCurrentUser()?.id ?? '';
    final shops  = await AppDatabase.getMyShops();
    debugPrint('[ShopRepo] ${shops.length} boutiques');
    return shops;
  }

  @override
  Future<ShopSummary> createShop(Map<String, dynamic> data) =>
      AppDatabase.createShop(
        name:     data['name']     as String,
        sector:   data['sector']   as String,
        currency: data['currency'] as String,
        country:  data['country']  as String,
        phone:    data['phone']    as String?,
        email:    data['email']    as String?,
      );

  @override
  Future<ShopSummary> updateShop(String shopId, Map<String, dynamic> data) =>
      AppDatabase.updateShop(
        shopId:   shopId,
        name:     data['name']     as String?,
        sector:   data['sector']   as String?,
        currency: data['currency'] as String?,
        country:  data['country']  as String?,
        phone:    data['phone']    as String?,
        email:    data['email']    as String?,
      );

  @override
  Future<void> selectShop(String shopId) async {
    final userId = LocalStorageService.getCurrentUser()?.id ?? '';
    LocalStorageService.saveActiveShopId(userId, shopId); // sync, pas d'await
  }
}