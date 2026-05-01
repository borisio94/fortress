import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../../core/services/activity_log_service.dart';
import '../../domain/repositories/auth_repository.dart';
import '../../domain/usecases/login_usecase.dart';
import '../../domain/usecases/register_usecase.dart';
import '../../domain/usecases/logout_usecase.dart';
import 'auth_event.dart';
import 'auth_state.dart';

class AuthBloc extends Bloc<AuthEvent, AuthState> {
  final LoginUseCase    loginUseCase;
  final RegisterUseCase registerUseCase;
  final LogoutUseCase   logoutUseCase;
  final AuthRepository  authRepository;

  AuthBloc({
    required this.loginUseCase,
    required this.registerUseCase,
    required this.logoutUseCase,
    required this.authRepository,
  }) : super(AuthInitial()) {
    on<AuthLoginRequested>(_onLogin);
    on<AuthRegisterRequested>(_onRegister);
    on<AuthLogoutRequested>(_onLogout);
    on<AuthForgotPasswordRequested>(_onForgotPassword);
  }

  Future<void> _onLogin(
      AuthLoginRequested event, Emitter<AuthState> emit) async {
    emit(AuthLoading());
    try {
      final user = await loginUseCase(
          LoginParams(email: event.email, password: event.password));
      // Journalise la connexion — n'attend pas (ne bloque pas l'émission de l'état)
      unawaited(ActivityLogService.log(
        action:      'user_login',
        targetType:  'user',
        targetId:    user.id,
        targetLabel: user.name.isNotEmpty ? user.name : user.email,
      ));
      emit(AuthAuthenticated(user));
    } catch (e) {
      emit(AuthError(_extractMessage(e)));
    }
  }

  Future<void> _onRegister(
      AuthRegisterRequested event, Emitter<AuthState> emit) async {
    emit(AuthLoading());
    try {
      await registerUseCase(RegisterParams(
        name:     event.name,
        email:    event.email,
        password: event.password,
        phone:    event.phone,
      ));
      // Le datasource d'inscription a positionné l'user comme courant
      // (cache local + session Supabase). On le déconnecte pour forcer
      // une saisie explicite des identifiants — confirmation d'intention
      // et premier login conscient.
      await logoutUseCase();
      emit(AuthRegisterSuccess(event.email.trim().toLowerCase()));
    } catch (e) {
      emit(AuthError(_extractMessage(e)));
    }
  }

  Future<void> _onLogout(
      AuthLogoutRequested event, Emitter<AuthState> emit) async {
    try {
      await logoutUseCase();
      emit(AuthUnauthenticated());
    } catch (e) {
      emit(AuthError(_extractMessage(e)));
    }
  }

  Future<void> _onForgotPassword(
      AuthForgotPasswordRequested event, Emitter<AuthState> emit) async {
    emit(AuthLoading());
    try {
      await authRepository.forgotPassword(event.email.trim().toLowerCase());
      emit(AuthForgotPasswordSent());
    } catch (e) {
      emit(AuthError(_extractMessage(e)));
    }
  }

  /// Extrait un message lisible depuis n'importe quel type d'exception
  static String _extractMessage(Object e) {
    final s = e.toString();
    // Supprimer les préfixes techniques
    for (final prefix in [
      'Exception: ', 'ServerException: ', 'AuthException: ',
      'NetworkException: ', 'CacheException: ',
    ]) {
      if (s.startsWith(prefix)) return s.substring(prefix.length);
    }
    // Si c'est "Instance of '...'" → message générique
    if (s.startsWith('Instance of')) return 'Une erreur est survenue';
    return s;
  }
}