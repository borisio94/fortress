import '../entities/client.dart';
import '../repositories/client_repository.dart';

/// Récupère les clients d'une boutique depuis Hive (offline-first, instantané).
class GetClientsUseCase {
  final ClientRepository repository;
  const GetClientsUseCase(this.repository);

  List<Client> call(String shopId) => repository.getClients(shopId);
}
