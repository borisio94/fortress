import 'package:equatable/equatable.dart';

abstract class Failure extends Equatable {
  final String message;
  const Failure(this.message);
  @override
  List<Object> get props => [message];
}

class ServerFailure extends Failure {
  const ServerFailure([super.message = 'Erreur serveur']);
}

class NetworkFailure extends Failure {
  const NetworkFailure([super.message = 'Pas de connexion internet']);
}

class CacheFailure extends Failure {
  const CacheFailure([super.message = 'Erreur cache local']);
}

class AuthFailure extends Failure {
  const AuthFailure([super.message = 'Non autorisé']);
}

class ValidationFailure extends Failure {
  const ValidationFailure(super.message);
}
