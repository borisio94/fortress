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
class AuthRemoteDataSourceMock implements AuthRemoteDataSource {
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
      final r = await SupabaseService.client
          .from('plans').select('id').limit(1)
          .timeout(const Duration(seconds: 3));
      return r is List;
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

    await SecureStorageService.saveAccessToken('offline_token_$normalEmail');
    await LocalStorageService.setCurrentUserId(user.id);
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
    try { await _supabase.logout(); } catch (_) {}
    await LocalStorageService.clearCurrentUser();
    await SecureStorageService.clearTokens();
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