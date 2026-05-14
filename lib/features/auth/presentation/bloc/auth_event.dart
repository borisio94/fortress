import 'package:equatable/equatable.dart';

abstract class AuthEvent extends Equatable {
  @override
  List<Object?> get props => [];
}

class AuthLoginRequested extends AuthEvent {
  final String email;
  final String password;
  AuthLoginRequested({required this.email, required this.password});
  @override
  List<Object> get props => [email, password];
}

class AuthRegisterRequested extends AuthEvent {
  final String name;
  final String email;
  final String password;
  final String? phone;
  AuthRegisterRequested({required this.name, required this.email, required this.password, this.phone});
  @override
  List<Object?> get props => [name, email, password, phone];
}

/// Variante de `AuthRegisterRequested` qui **garde l'utilisateur connecté**
/// après inscription (skip du `logoutUseCase`). Utilisée par le tunnel
/// d'inscription self-service `/auth/register` (3 étapes) qui enchaîne
/// directement sur la création de boutique sans faire repasser l'utilisateur
/// par /login. Émet `AuthAuthenticated` directement.
class AuthSignUpAutoLoginRequested extends AuthEvent {
  final String  name;
  final String  email;
  final String  password;
  final String? phone;
  AuthSignUpAutoLoginRequested({
    required this.name,
    required this.email,
    required this.password,
    this.phone,
  });
  @override
  List<Object?> get props => [name, email, password, phone];
}

class AuthLogoutRequested extends AuthEvent {}
class AuthCheckRequested extends AuthEvent {}
class AuthForgotPasswordRequested extends AuthEvent {
  final String email;
  AuthForgotPasswordRequested(this.email);
  @override
  List<Object> get props => [email];
}
