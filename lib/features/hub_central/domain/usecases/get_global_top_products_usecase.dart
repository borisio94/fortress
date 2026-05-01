import 'get_all_shops_stats_usecase.dart';

class GetGlobalTopProductsUseCase {
  final HubRepository repository;
  const GetGlobalTopProductsUseCase(this.repository);
  Future<Map<String, dynamic>> call(String period) async =>
      {'products': []};
}
