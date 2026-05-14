import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show Supabase;
import '../../../../core/services/activity_log_service.dart';
import '../../../../core/services/pin_service.dart';
import '../../../../core/services/session_service.dart';
import '../../../../core/storage/local_storage_service.dart';
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
    on<AuthSignUpAutoLoginRequested>(_onSignUpAutoLogin);
    on<AuthLogoutRequested>(_onLogout);
    on<AuthForgotPasswordRequested>(_onForgotPassword);
    on<AuthCheckRequested>(_onCheck);
    // Boot : valide la session restaurée par Supabase (au refresh) et
    // évite de renvoyer un utilisateur connecté vers /login. Sans ce
    // check, AuthBloc reste en AuthInitial → notifier.isAuthenticated
    // = false → redirect /login alors que la session est valide.
    add(AuthCheckRequested());
  }

  Future<void> _onCheck(
      AuthCheckRequested event, Emitter<AuthState> emit) async {
    final session = Supabase.instance.client.auth.currentSession;
    final supaUser = Supabase.instance.client.auth.currentUser;
    final localUser = LocalStorageService.getCurrentUser();
    final hasValidSession = session != null && !session.isExpired
        && supaUser != null;
    if (hasValidSession && localUser != null) {
      // Re-enregistre la session au boot (refresh navigateur, redémarrage
      // app). Le backend met à jour last_seen et confirme la limite.
      unawaited(SessionService.register());
      // Hydrate le PIN depuis profiles si configuré sur un autre device
      // mais pas encore caché localement (cas typique : mobile fresh install
      // alors que le PIN a été configuré sur desktop).
      unawaited(PinService.hydrateOnLogin());
      emit(AuthAuthenticated(localUser));
    } else {
      emit(AuthUnauthenticated());
    }
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
      // Enregistre la session côté Supabase (limites par rôle gérées
      // backend). Non-bloquant — si le réseau échoue, on entre quand même.
      unawaited(SessionService.register());
      // Hydrate le PIN depuis profiles si déjà configuré sur un autre
      // device. Le user n'aura pas à le re-configurer.
      unawaited(PinService.hydrateOnLogin());
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

  /// Variante self-service du sign-up qui **conserve la session active**.
  /// Utilisée par le tunnel inscription 3 étapes (cf. `register_page.dart`)
  /// qui doit enchaîner sur la création de boutique sans repasser par /login.
  /// Émet `AuthAuthenticated(user)` directement (vs `AuthRegisterSuccess`).
  Future<void> _onSignUpAutoLogin(
      AuthSignUpAutoLoginRequested event, Emitter<AuthState> emit) async {
    emit(AuthLoading());
    try {
      final user = await registerUseCase(RegisterParams(
        name:     event.name,
        email:    event.email,
        password: event.password,
        phone:    event.phone,
      ));
      // Pas de `logoutUseCase()` — le datasource a déjà positionné l'user
      // comme courant (cache local + session Supabase). On enregistre la
      // session côté serveur et hydrate le PIN (idempotent : ne fera rien
      // si fresh signup sans PIN cross-device).
      unawaited(ActivityLogService.log(
        action:      'user_signup',
        targetType:  'user',
        targetId:    user.id,
        targetLabel: user.name.isNotEmpty ? user.name : user.email,
      ));
      unawaited(SessionService.register());
      unawaited(PinService.hydrateOnLogin());
      emit(AuthAuthenticated(user));
    } catch (e) {
      emit(AuthError(_extractMessage(e)));
    }
  }

  Future<void> _onLogout(
      AuthLogoutRequested event, Emitter<AuthState> emit) async {
    try {
      // Révoque la session courante côté Supabase AVANT le logout local —
      // sinon on perd le token nécessaire pour appeler le RPC.
      await SessionService.revokeCurrent();
      SessionService.stop();
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