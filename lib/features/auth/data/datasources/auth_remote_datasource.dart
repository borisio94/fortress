import 'package:flutter/foundation.dart' show debugPrint;

import '../../../../core/error/exceptions.dart';
import '../../../../core/storage/secure_storage.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/storage/hive_boxes.dart';
import '../../../../core/services/supabase_service.dart';
import '../datasources/auth_supabase_datasource.dart';
import '../models/user_model.dart';

abstract class AuthRemoteDataSource {
  Future<UserModel> login({required String email, required String password});
  Future<UserModel> register({
    required String name, required String email,
    required String password, String? phone,
  });
  Future<void>      logout();
  Future<UserModel?> getCurrentUser();
  Future<void>      forgotPassword(String email);
  Future<bool>      isAuthenticated();
}

// ─────────────────────────────────────────────────────────────────────────────
// Supabase Auth + fallback Hive offline
// ─────────────────────────────────────────────────────────────────────────────
/// L'IMPLÉMENTATION RÉELLE. Elle s'appelait `AuthRemoteDataSourceMock`
/// jusqu'au 21/09/2026, et c'est la seule qui existe : `injection_container`
/// la câble en production, chaque connexion et chaque inscription passent par
/// elle. Le nom a trompé un audit du parcours d'entrée, qui a cherché ailleurs
/// le code qui authentifie vraiment.
class AuthRemoteDataSourceImpl implements AuthRemoteDataSource {
  final _supabase = AuthSupabaseDataSource();

  @override
  Future<UserModel> login({
    required String email,
    required String password,
  }) async {
    UserModel user;
    final wasOnline = await _hasNetwork();

    try {
      user = await _supabase.login(email: email, password: password);
    } on ServerException catch (e) {
      final isAuthError = e.statusCode == 401 || e.statusCode == 400;
      if (isAuthError) rethrow;
      // Erreur serveur (5xx) — fallback offline UNIQUEMENT si réellement
      // hors-ligne. Sinon on refuse : un compte serveur peut avoir été
      // supprimé entre-temps, le cache Hive ne fait pas autorité.
      if (wasOnline) rethrow;
      user = await _offlineLogin(email: email, password: password);
    } catch (_) {
      // Exception non-ServerException = typiquement une erreur réseau
      // (timeout, DNS). On ne tombe sur Hive que si on était bien offline.
      if (wasOnline) rethrow;
      user = await _offlineLogin(email: email, password: password);
    }
    // Mémoriser l'email pour pré-remplir la prochaine ouverture de login.
    // Volontairement préservé au logout.
    await LocalStorageService.saveLastLoginEmail(email);
    return user;
  }

  /// Test rapide de connectivité : on demande au DNS si supabase répond.
  /// Si l'appareil est en avion / Wi-Fi sans accès, retourne false en <2s.
  Future<bool> _hasNetwork() async {
    try {
      await SupabaseService.client
          .from('plans').select('id').limit(1)
          .timeout(const Duration(seconds: 3));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<UserModel> _offlineLogin({
    required String email,
    required String password,
  }) async {
    await Future.delayed(const Duration(milliseconds: 300));
    final normalEmail = email.trim().toLowerCase();
    final normalPass  = password.trim();

    final allUsers = LocalStorageService.getAllUsers();
    final user = allUsers
        .where((u) => u.email.toLowerCase() == normalEmail)
        .firstOrNull;

    if (user == null) {
      throw const ServerException(
        message: 'Email ou mot de passe incorrect. Vérifiez vos identifiants.',
        statusCode: 404,
      );
    }

    String? storedPwd = await SecureStorageService.getPassword(normalEmail);
    if (storedPwd == null || storedPwd.isEmpty) {
      final rawMap = HiveBoxes.usersBox.get(user.id);
      if (rawMap != null) {
        storedPwd =
        (Map<String, dynamic>.from(rawMap))['_pwd'] as String?;
      }
    }

    if (storedPwd == null || storedPwd != normalPass) {
      throw const ServerException(
          message: 'Email ou mot de passe incorrect. Vérifiez vos identifiants.',
          statusCode: 401);
    }

    // ISOLATION (anti-fuite inter-comptes, appareil partagé) — même garde que
    // le login EN LIGNE, qui l'avait et que celui-ci n'avait pas. L'écart est
    // resté sans conséquence tant que la déconnexion emportait tout : plus
    // rien ne subsistait d'un autre compte. Depuis que la file d'envoi survit
    // à la déconnexion, l'écart devient une fuite — les écritures du compte
    // précédent partiraient sous la session de celui-ci.
    final previousOwner = LocalStorageService.getLocalDataOwnerId();
    if (previousOwner != null && previousOwner != user.id) {
      debugPrint('[Auth] connexion hors ligne : données locales d\'un autre '
          'compte ($previousOwner ≠ ${user.id}) → purge anti-fuite');
      // Même contrepartie qu'en ligne : le secret du compte précédent part
      // AVANT la purge, tant que sa fiche porte encore son e-mail.
      final previous = LocalStorageService.getUser(previousOwner);
      final mail = previous?.email.trim().toLowerCase() ?? '';
      if (mail.isNotEmpty) {
        await SecureStorageService.deletePassword(mail);
      }
      await LocalStorageService.purgeOnLogout();
      // La purge a emporté la boîte `users`, DONT la fiche qu'on vient
      // d'authentifier. Le chemin EN LIGNE la ré-écrit juste après (`saveUser`
      // après la garde) ; celui-ci ne le faisait pas, et `setCurrentUserId`
      // ci-dessous aurait pointé sur une fiche absente — session ouverte,
      // utilisateur introuvable au redémarrage suivant.
      await LocalStorageService.saveUser(user);
    }

    // PAS DE JETON FACTICE. On écrivait ici `offline_token_<email>` dans le
    // stockage sécurisé ET dans Hive. Rien ne l'a jamais relu : la session
    // réelle appartient à gotrue, et une connexion hors ligne n'en ouvre
    // aucune. Ça donnait l'apparence d'un jeton là où il n'y en a pas.
    await LocalStorageService.setCurrentUserId(user.id);
    await LocalStorageService.setLocalDataOwnerId(user.id);
    return UserModel.fromEntity(user);
  }

  @override
  Future<UserModel> register({
    required String name,
    required String email,
    required String password,
    String? phone,
  }) async {
    return await _supabase.register(
        name: name, email: email, password: password, phone: phone);
  }

  @override
  Future<void> logout() async {
    // Nettoyage LOCAL D'ABORD — ne dépend d'aucun réseau, donc ne peut JAMAIS
    // bloquer la déconnexion. CAUSE RACINE du « ne redirige pas vers /login » :
    // quand `_supabase.logout()` (signOut) se bloquait (réseau lent / verrou
    // multi-onglet GoTrue sur web), la purge + le clear tokens placés APRÈS ne
    // s'exécutaient pas, et `_onLogout` n'atteignait jamais son `emit`.
    //
    // Anti-fuite inter-comptes (appareil partagé) : purge TOUTES les données
    // métier locales (produits, prix d'achat, clients, panier, ventes
    // offline…) en conservant les préférences device (taille de texte, thème,
    // dernier email…). Remplace l'ancien clearCurrentUser (qui n'effaçait que
    // l'id et laissait tout le reste en clair dans Hive).
    await LocalStorageService.purgeOnLogout();
    await SecureStorageService.clearTokens();
    // signOut Supabase (efface la session GoTrue locale) — BORNÉ par un timeout
    // pour ne jamais figer la déconnexion si le réseau ou le verrou GoTrue
    // multi-onglet (web) bloque. Best-effort : la session locale est déjà
    // purgée ci-dessus.
    try {
      await _supabase.logout().timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  @override
  Future<UserModel?> getCurrentUser() async {
    if (SupabaseService.isAuthenticated) {
      try { return await _supabase.getCurrentUser(); } catch (_) {}
    }
    final cached = LocalStorageService.getCurrentUser();
    if (cached != null) return UserModel.fromEntity(cached);
    return null;
  }

  @override
  Future<bool> isAuthenticated() async =>
      SupabaseService.isAuthenticated ||
          LocalStorageService.getCurrentUser() != null;

  @override
  Future<void> forgotPassword(String email) async {
    try {
      await _supabase.forgotPassword(email);
    } catch (_) {
      await Future.delayed(const Duration(milliseconds: 300));
    }
  }
}