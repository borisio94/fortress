import '../../domain/entities/client.dart';
import '../../domain/repositories/client_repository.dart';
import '../../../../core/database/app_database.dart';

/// Implémentation du repository clients.
/// Délègue entièrement à [AppDatabase] qui gère :
///   • Hive  — lecture/écriture immédiate (offline-first)
///   • Supabase — synchronisation en arrière-plan
class ClientRepositoryImpl implements ClientRepository {
  const ClientRepositoryImpl();

  @override
  List<Client> getClients(String shopId) =>
      AppDatabase.getClientsForShop(shopId);

  @override
  Future<void> saveClient(Client client) =>
      AppDatabase.saveClient(client);

  @override
  Future<void> deleteClient(String clientId, String shopId) =>
      AppDatabase.deleteClient(clientId, shopId);

  @override
  Future<void> syncClients(String shopId) =>
      AppDatabase.syncClients(shopId);

  @override
  List<String> getDistinctCities(String shopId) =>
      AppDatabase.getDistinctClientCities(shopId);

  @override
  List<String> getDistinctDistricts(String shopId) =>
      AppDatabase.getDistinctClientDistricts(shopId);
}
