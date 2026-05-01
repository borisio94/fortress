import '../entities/global_stats.dart';
import 'get_all_shops_stats_usecase.dart';

class CompareShopsUseCase {
  final HubRepository repository;
  const CompareShopsUseCase(this.repository);
  Future<GlobalStats> call(List<String> shopIds, String period) =>
      repository.compareShops(shopIds, period);
}
