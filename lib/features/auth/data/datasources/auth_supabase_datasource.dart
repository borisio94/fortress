import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthException;
import '../../../../core/error/exceptions.dart';
import '../../../../core/services/supabase_service.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/storage/hive_boxes.dart';
import '../../../../core/storage/secure_storage.dart';
import '../../../../core/database/app_database.dart';
import '../models/user_model.dart';

// ─────────────────────────────────────────────────────────────────────────────
// AuthSupabaseDataSource
// Responsabilité unique : authentification via Supabase Auth
// Toutes les opérations de données passent par AppDatabase
// ─────────────────────────────────────────────────────────────────────────────

class AuthSupabaseDataSource {
  final _auth   = SupabaseService.auth;
  final _client = SupabaseService.client;

  // ── Inscription ───────────────────────────────────────────────────────────
  Future<UserModel> register({
    required String name,
    required String email,
    required String password,
    String? phone,
  }) async {
    // Vérifier la connexion internet AVANT tout
    final online = await AppDatabase.isOnline();
    if (!online) {
      throw const ServerException(
        message: 'Connexion internet requise pour créer un compte. '
            'Votre compte sera accessible sur tous vos appareils une fois créé.',
        statusCode: 503,
      );
    }

    try {
      final res = await _auth.signUp(
        email:    email.trim().toLowerCase(),
        password: password,
        data:     {'name': name.trim(), 'phone': phone},
      );

      if (res.user == null) {
        throw const ServerException(message: 'Inscription échouée', statusCode: 400);
      }

      final userId = res.user!.id;
      final userEmail = email.trim().toLowerCase();

      // Créer le profil dans Supabase via AppDatabase
      await _client.from('profiles').upsert({
        'id':    userId,
        'name':  name.trim(),
        'email': userEmail,
        'phone': phone,
      });

      final model = UserModel(
        id:        userId,
        name:      name.trim(),
        email:     userEmail,
        phone:     phone,
        createdAt: DateTime.now(),
      );

      // Cache local + mot de passe pour offline
      await LocalStorageService.saveUser(model.toEntity());
      await LocalStorageService.setCurrentUserId(userId);
      await _cachePwdForOffline(userEmail, password);

      debugPrint('[Auth] Inscription réussie: $userId');
      return model;

    } on AuthException catch (e) {
      throw ServerException(message: _mapError(e.message), statusCode: 400);
    } catch (e) {
      if (e is ServerException) rethrow;
      throw ServerException(message: _extractMessage(e), statusCode: 500);
    }
  }

  // ── Connexion ─────────────────────────────────────────────────────────────
  Future<UserModel> login({
    required String email,
    required String password,
  }) async {
    try {
      final res = await _auth.signInWithPassword(
        email:    email.trim().toLowerCase(),
        password: password,
      );

      if (res.user == null) {
        throw const ServerException(message: 'Connexion échouée', statusCode: 401);
      }

      final userId    = res.user!.id;
      final userEmail = res.user!.email ?? '';

      // Récupérer le profil — le créer s'il n'existe pas (trigger async)
      var profileData = await _client
          .from('profiles').select().eq('id', userId).maybeSingle();

      if (profileData == null) {
        await _client.from('profiles').upsert({
          'id':    userId,
          'name':  userEmail.split('@').first,
          'email': userEmail,
        });
        profileData = await _client
            .from('profiles').select().eq('id', userId).maybeSingle();
      }

      final model = UserModel(
        id:        userId,
        name:      profileData?['name'] ?? userEmail.split('@').first,
        email:     userEmail,
        phone:     profileData?['phone'],
        createdAt: DateTime.parse(
            profileData?['created_at'] ?? DateTime.now().toIso8601String()),
      );

      // Cache local
      await LocalStorageService.saveUser(model.toEntity());
      await LocalStorageService.setCurrentUserId(userId);
      await _cachePwdForOffline(email.trim().toLowerCase(), password);

      // Sync en arrière-plan — ne bloque PAS le login
      // InventairePage et ShopListPage gèrent leur propre sync
      AppDatabase.syncOnLogin(userId).catchError((e) {
        debugPrint('[Auth] syncOnLogin background: $e');
        return null;
      });

      debugPrint('[Auth] Connexion réussie: $userId');
      return model;

    } on AuthException catch (e) {
      throw ServerException(message: _mapError(e.message), statusCode: 401);
    } catch (e) {
      if (e is ServerException) rethrow;
      throw ServerException(message: _extractMessage(e), statusCode: 500);
    }
  }

  // ── Déconnexion ───────────────────────────────────────────────────────────
  Future<void> logout() async {
    try { await _auth.signOut(); } catch (_) {}
    await LocalStorageService.clearCurrentUser();
  }

  // ── Utilisateur courant ───────────────────────────────────────────────────
  Future<UserModel> getCurrentUser() async {
    final user = _auth.currentUser;
    if (user == null) throw const ServerException(statusCode: 401);

    // Cache Hive d'abord
    final cached = LocalStorageService.getCurrentUser();
    if (cached != null) return UserModel.fromEntity(cached);

    // Sinon Supabase
    final data = await _client
        .from('profiles').select().eq('id', user.id).maybeSingle();
    final model = UserModel(
      id:        user.id,
      name:      data?['name'] ?? user.email ?? '',
      email:     user.email ?? '',
      phone:     data?['phone'],
      createdAt: DateTime.now(),
    );
    await LocalStorageService.saveUser(model.toEntity());
    await LocalStorageService.setCurrentUserId(user.id);
    return model;
  }

  // ── Reset mot de passe (legacy, non utilisé — flux actuel = OTP) ─────────
  // Conservé pour compatibilité si un jour on veut réactiver le magic-link.
  Future<void> forgotPassword(String email) async {
    await _auth.resetPasswordForEmail(email.trim().toLowerCase());
  }

  // ── Détection super admin avant auth ─────────────────────────────────────
  // Appelle le RPC hotfix_006 qui ne renvoie qu'un booléen (pas de leak).
  Future<bool> isSuperAdminEmail(String email) async {
    try {
      final res = await _client.rpc(
        'is_super_admin_email',
        params: {'p_email': email.trim().toLowerCase()},
      );
      return res == true;
    } catch (e) {
      debugPrint('[Auth] isSuperAdminEmail fallback=false: $e');
      return false;
    }
  }

  // ── OTP email pour reset mot de passe ────────────────────────────────────
  // Utilise le flux "recovery" de Supabase (resetPasswordForEmail) qui est
  // toujours activé par défaut et n'exige pas d'autoriser les signups OTP.
  // Supabase renvoie dans le même email un magic-link ET un code 6 chiffres
  // (variable {{ .Token }} du template).
  Future<void> sendEmailOtp(String email) async {
    await _auth.resetPasswordForEmail(email.trim().toLowerCase());
  }

  Future<void> verifyEmailOtp({
    required String email, required String token,
  }) async {
    final res = await _auth.verifyOTP(
      email: email.trim().toLowerCase(),
      token: token.trim(),
      type: OtpType.recovery,
    );
    if (res.session == null) {
      throw const ServerException(
        message: 'Code invalide ou expiré', statusCode: 401);
    }
  }

  // ── Mise à jour du mot de passe (session active requise) ─────────────────
  Future<void> updatePassword(String newPassword) async {
    await _auth.updateUser(UserAttributes(password: newPassword));
  }

  // ── Déconnexion globale (toutes les sessions du compte) ──────────────────
  Future<void> signOutGlobal() async {
    await _auth.signOut(scope: SignOutScope.global);
    await LocalStorageService.clearCurrentUser();
  }

  bool get isAuthenticated => _auth.currentUser != null;

  // ── Mot de passe pour login offline ──────────────────────────────────────
  // Stocké UNIQUEMENT dans le keystore système (Android Keystore / iOS
  // Keychain) via SecureStorageService — plus jamais en clair dans Hive.
  // Si l'appareil est volé, le keystore système chiffre la valeur avec
  // une clé matérielle ; un dump du dossier `/data/data/.../hive/` ne
  // suffit plus à extraire le mot de passe.
  Future<void> _cachePwdForOffline(String email, String password) async {
    try {
      await SecureStorageService.savePassword(email, password);
    } catch (e) {
      debugPrint('[Auth] cache pwd offline failed: $e');
    }
  }

  // ── Traduction des erreurs ────────────────────────────────────────────────
  String _mapError(String msg) {
    final m = msg.toLowerCase();

    // Supabase retourne "invalid login credentials" pour 2 cas :
    // 1. Compte inexistant  2. Mauvais mot de passe
    // On vérifie en cache Hive si l'email a déjà été utilisé pour distinguer
    if (m.contains('invalid login') || m.contains('invalid credentials') ||
        m.contains('user not found') || m.contains('no user') ||
        m.contains('wrong password') || m.contains('incorrect password'))
      return 'Email ou mot de passe incorrect. Vérifiez vos identifiants.';
    if (m.contains('email already') || m.contains('already registered'))
      return 'Un compte avec cet email existe déjà';
    if (m.contains('weak password') || m.contains('password should'))
      return 'Mot de passe trop faible — minimum 8 caractères avec une majuscule et un chiffre';
    if (m.contains('network') || m.contains('connection') || m.contains('offline'))
      return 'Pas de connexion internet';
    if (m.contains('security purposes') ||
        (m.contains('after') && m.contains('second')))
      return 'Trop de tentatives — attendez 60 secondes avant de réessayer';
    if (m.contains('rate limit') || m.contains('too many'))
      return 'Trop de tentatives — attendez quelques minutes';
    if (m.contains('email not confirmed'))
      return 'Email non confirmé — vérifiez votre boîte mail';
    if (m.contains('signup disabled'))
      return 'Les inscriptions sont temporairement désactivées';
    if (m.contains('otp') || m.contains('token'))
      return 'Lien expiré — veuillez recommencer';
    return msg.isNotEmpty ? msg : 'Une erreur est survenue, veuillez réessayer';
  }

  /// Vérifie si un email est déjà enregistré localement (cache Hive)
  bool _emailExistsLocally(String email) {
    return LocalStorageService.getAllUsers()
        .any((u) => u.email.toLowerCase() == email.toLowerCase());
  }

  /// Extrait un message lisible depuis n'importe quel type d'exception Supabase
  String _extractMessage(Object e) {
    try {
      final dynamic err = e;
      final msg = err.message as String?;
      if (msg != null && msg.isNotEmpty) return _mapError(msg);
    } catch (_) {}
    final s = e.toString();
    if (s.startsWith('Instance of')) return 'Une erreur est survenue';
    if (s.contains('Exception:')) return s.split('Exception:').last.trim();
    return s.isNotEmpty ? s : 'Une erreur est survenue';
  }
}