import '../entities/client.dart';

/// Interface du repository clients.
/// Implémentation : [ClientRepositoryImpl] dans data/repositories/
abstract class ClientRepository {
  /// Lire depuis Hive (instantané, offline-first)
  List<Client> getClients(String shopId);

  /// Sauvegarder : Hive immédiat + Supabase background
  Future<void> saveClient(Client client);

  /// Supprimer : Hive immédiat + Supabase background
  Future<void> deleteClient(String clientId, String shopId);

  /// Sync depuis Supabase → Hive
  Future<void> syncClients(String shopId);

  /// Villes distinctes déjà renseignées pour ce shop — alimente
  /// l'autocomplétion du formulaire client.
  List<String> getDistinctCities(String shopId);

  /// Quartiers distincts déjà renseignés pour ce shop.
  List<String> getDistinctDistricts(String shopId);
}
