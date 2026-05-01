import 'package:equatable/equatable.dart';
import '../../domain/entities/user.dart';

abstract class AuthState extends Equatable {
  @override
  List<Object?> get props => [];
}

class AuthInitial extends AuthState {}
class AuthLoading extends AuthState {}

class AuthAuthenticated extends AuthState {
  final User user;
  AuthAuthenticated(this.user);
  @override
  List<Object> get props => [user];
}

class AuthUnauthenticated extends AuthState {}

class AuthError extends AuthState {
  final String message;
  AuthError(this.message);
  @override
  List<Object> get props => [message];
}

class AuthForgotPasswordSent extends AuthState {}

/// Inscription réussie mais l'utilisateur n'est PAS authentifié : on le
/// redirige vers la page de connexion pour qu'il saisisse ses identifiants.
class AuthRegisterSuccess extends AuthState {
  final String email;
  AuthRegisterSuccess(this.email);
  @override
  List<Object> get props => [email];
}
