import '../entities/global_stats.dart';

abstract class HubRepository {
  Future<GlobalStats> getAllShopsStats(String period);
  Future<GlobalStats> compareShops(List<String> shopIds, String period);
}

class GetAllShopsStatsUseCase {
  final HubRepository repository;
  const GetAllShopsStatsUseCase(this.repository);
  Future<GlobalStats> call(String period) => repository.getAllShopsStats(period);
}
