import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'hive_boxes.dart';

class SecureStorageService {
  static const _storage = FlutterSecureStorage(
    // Options Android — utiliser encryptedSharedPreferences comme fallback
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      resetOnError: true,
    ),
  );

  static const _accessTokenKey  = 'access_token';
  static const _refreshTokenKey = 'refresh_token';
  static const _userIdKey       = 'user_id';

  // ── Tokens ─────────────────────────────────────────────────────────────────

  static Future<void> saveAccessToken(String token) async {
    try { await _storage.write(key: _accessTokenKey, value: token); } catch (_) {}
    // Fallback Hive
    await HiveBoxes.settingsBox.put('_token_access', token);
  }

  static Future<String?> getAccessToken() async {
    try {
      final v = await _storage.read(key: _accessTokenKey);
      if (v != null && v.isNotEmpty) return v;
    } catch (_) {}
    // Fallback Hive
    return HiveBoxes.settingsBox.get('_token_access') as String?;
  }

  static Future<void> saveRefreshToken(String token) async {
    try { await _storage.write(key: _refreshTokenKey, value: token); } catch (_) {}
    await HiveBoxes.settingsBox.put('_token_refresh', token);
  }

  static Future<String?> getRefreshToken() async {
    try {
      final v = await _storage.read(key: _refreshTokenKey);
      if (v != null && v.isNotEmpty) return v;
    } catch (_) {}
    return HiveBoxes.settingsBox.get('_token_refresh') as String?;
  }

  /// Efface uniquement les tokens (pas les mots de passe)
  static Future<void> clearTokens() async {
    try {
      await _storage.delete(key: _accessTokenKey);
      await _storage.delete(key: _refreshTokenKey);
      await _storage.delete(key: _userIdKey);
    } catch (_) {}
    // Fallback Hive
    await HiveBoxes.settingsBox.delete('_token_access');
    await HiveBoxes.settingsBox.delete('_token_refresh');
    await HiveBoxes.settingsBox.delete('_token_userid');
  }

  // ── Mots de passe ─────────────────────────────────────────────────────────
  // Stockés UNIQUEMENT dans le keystore système (Android Keystore / iOS
  // Keychain) — chiffrés au repos par une clé matérielle. Plus aucune
  // écriture en clair dans Hive (sécurité critique : un dump du dossier
  // `/data/data/.../hive/` ne suffit pas à les extraire).
  //
  // Une lecture legacy depuis Hive est tolérée pour migrer en douceur les
  // installations existantes : si trouvé en Hive, on copie vers SecureStorage
  // puis on efface l'entrée Hive.

  static String _pwdKey(String email) => 'pwd_${email.toLowerCase().trim()}';
  static String _legacyHivePwdKey(String email) =>
      '_pwd_${email.toLowerCase().trim()}';

  static Future<void> savePassword(String email, String password) async {
    final key = _pwdKey(email);
    try {
      await _storage.write(key: key, value: password);
    } catch (e) {
      // Si SecureStorage échoue (rare : encryptedSharedPreferences corrompu),
      // on n'écrit PAS de fallback en clair. Mieux vaut perdre l'offline-login
      // qu'exposer le mot de passe.
    }
    // Sécurité : si une ancienne valeur traînait en clair dans Hive, on
    // la supprime au passage à chaque sauvegarde.
    await HiveBoxes.settingsBox.delete(_legacyHivePwdKey(email));
  }

  static Future<String?> getPassword(String email) async {
    // 1. Source canonique : SecureStorage.
    try {
      final v = await _storage.read(key: _pwdKey(email));
      if (v != null && v.isNotEmpty) return v;
    } catch (_) {}
    // 2. Lecture legacy Hive (entrées créées avant ce hotfix). Migrer
    // vers SecureStorage et effacer Hive immédiatement.
    final legacy = HiveBoxes.settingsBox.get(_legacyHivePwdKey(email))
        as String?;
    if (legacy != null && legacy.isNotEmpty) {
      try {
        await _storage.write(key: _pwdKey(email), value: legacy);
      } catch (_) {}
      await HiveBoxes.settingsBox.delete(_legacyHivePwdKey(email));
      return legacy;
    }
    return null;
  }

  static Future<void> deletePassword(String email) async {
    try { await _storage.delete(key: _pwdKey(email)); } catch (_) {}
    await HiveBoxes.settingsBox.delete(_legacyHivePwdKey(email));
  }

  /// One-shot : MIGRE les mots de passe legacy stockés en clair dans Hive
  /// (champ `_pwd` dans `usersBox`, clés `_pwd_<email>` dans `settingsBox`)
  /// vers SecureStorage, puis efface l'entrée Hive.
  ///
  /// L'offline login reste fonctionnel pour les installations existantes :
  /// le mot de passe est juste déplacé vers le keystore système au lieu
  /// d'être perdu. Idempotent — ne fait rien si déjà clean.
  ///
  /// Retourne le nombre d'entrées migrées (pour log).
  static Future<int> purgeLegacyPlaintextPasswords() async {
    int migrated = 0;

    // 1. settingsBox : `_pwd_<email>` → SecureStorage(pwd_<email>).
    final keys = HiveBoxes.settingsBox.keys
        .where((k) => k.toString().startsWith('_pwd_'))
        .toList();
    for (final k in keys) {
      try {
        final pwd = HiveBoxes.settingsBox.get(k) as String?;
        if (pwd != null && pwd.isNotEmpty) {
          // Email = portion après `_pwd_`
          final email = k.toString().substring('_pwd_'.length);
          try {
            await _storage.write(key: _pwdKey(email), value: pwd);
            migrated++;
          } catch (_) {
            // Si SecureStorage indisponible, on n'efface PAS la valeur
            // legacy (sinon offline-login cassé). Ré-essai au prochain
            // démarrage.
            continue;
          }
        }
        await HiveBoxes.settingsBox.delete(k);
      } catch (_) {}
    }

    // 2. usersBox : champ `_pwd` injecté par l'ancien _cachePwdForOffline.
    for (final k in HiveBoxes.usersBox.keys.toList()) {
      try {
        final raw = HiveBoxes.usersBox.get(k);
        if (raw is! Map) continue;
        final m = Map<String, dynamic>.from(raw);
        final legacyPwd = m['_pwd'] as String?;
        if (legacyPwd == null || legacyPwd.isEmpty) continue;
        final email = (m['email'] as String?)?.toLowerCase().trim();
        if (email == null || email.isEmpty) {
          // Pas d'email → impossible de migrer, on retire juste le champ.
          m.remove('_pwd');
          await HiveBoxes.usersBox.put(k, m);
          continue;
        }
        try {
          await _storage.write(key: _pwdKey(email), value: legacyPwd);
          m.remove('_pwd');
          await HiveBoxes.usersBox.put(k, m);
          migrated++;
        } catch (_) {
          // SecureStorage KO : on garde la valeur legacy (offline-login).
        }
      } catch (_) {}
    }
    return migrated;
  }

  // ── UserId ─────────────────────────────────────────────────────────────────

  static Future<void> saveUserId(String id) async {
    try { await _storage.write(key: _userIdKey, value: id); } catch (_) {}
    await HiveBoxes.settingsBox.put('_token_userid', id);
  }

  static Future<String?> getUserId() async {
    try {
      final v = await _storage.read(key: _userIdKey);
      if (v != null && v.isNotEmpty) return v;
    } catch (_) {}
    return HiveBoxes.settingsBox.get('_token_userid') as String?;
  }

  /// Efface TOUT (tokens + mots de passe) — à n'utiliser qu'en dev/reset
  static Future<void> clearAll() async {
    try { await _storage.deleteAll(); } catch (_) {}
    // Effacer aussi les clés Hive correspondantes
    final keys = HiveBoxes.settingsBox.keys
        .where((k) => k.toString().startsWith('_token_') ||
        k.toString().startsWith('_pwd_'))
        .toList();
    for (final k in keys) {
      await HiveBoxes.settingsBox.delete(k);
    }
  }
}
