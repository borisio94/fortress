import '../entities/client.dart';
import '../repositories/client_repository.dart';

/// Recherche un client par numéro de téléphone dans une boutique.
/// Lecture Hive uniquement (offline-first, instantanée).
class GetClientByPhoneUseCase {
  final ClientRepository repository;
  const GetClientByPhoneUseCase(this.repository);

  Client? call(String phone, String shopId) {
    return repository
        .getClients(shopId)
        .where((c) => c.phone == phone)
        .firstOrNull;
  }
}
