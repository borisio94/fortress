class ServerException implements Exception {
  final String message;
  final int? statusCode;
  const ServerException({this.message = 'Erreur serveur', this.statusCode});
  @override String toString() => message;
}

class NetworkException implements Exception {
  const NetworkException();
  @override String toString() => 'Erreur réseau — vérifiez votre connexion';
}

class CacheException implements Exception {
  final String message;
  const CacheException([this.message = 'Erreur cache']);
  @override String toString() => message;
}

class AuthException implements Exception {
  final String message;
  const AuthException([this.message = 'Non autorisé']);
  @override String toString() => message;
}