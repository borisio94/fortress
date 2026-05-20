import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../storage/hive_boxes.dart';

/// Service de gestion du code PIN propriétaire (4 chiffres).
///
/// Sécurité :
///  - Le PIN n'est jamais stocké en clair. On garde uniquement
///    `SHA-256(salt + pin)` dans le keystore système.
///  - Un sel aléatoire de 16 octets est généré par device au premier
///    enregistrement, stocké dans SecureStorage.
///  - Après 3 tentatives infructueuses, le service se verrouille pendant
///    15 minutes (timestamp persisté en Hive — non sensible).
///  - Le compteur d'essais et le verrou survivent au redémarrage de l'app.
class PinService {
  static const _kHashKey       = 'owner_pin_hash';
  static const _kSaltKey       = 'owner_pin_salt';
  static const _kAttemptsKey   = '_pin_attempts';
  static const _kLockUntilKey  = '_pin_lock_until';

  static const int maxAttempts = 3;
  static const Duration lockDuration = Duration(minutes: 15);
  static const int pinLength = 4;

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      resetOnError: true,
    ),
  );

  /// Vrai si un PIN propriétaire a déjà été enregistré pour ce compte.
  ///
  /// Stratégie multi-device : on regarde d'abord SecureStorage (rapide,
  /// disponible offline), et si rien n'y est on tente Supabase profiles
  /// (un autre device a peut-être déjà enregistré le PIN). Au premier
  /// hit serveur, on cache localement pour les vérifs futures et pour
  /// le mode offline.
  static Future<bool> hasPIN() async {
    try {
      final hash = await _storage.read(key: _kHashKey);
      if (hash != null && hash.isNotEmpty) return true;
    } catch (_) {/* ignore secure storage failure */}
    return await _hydrateFromRemote();
  }

  /// Enregistre (ou remplace) le PIN. Génère un nouveau sel, persiste en
  /// SecureStorage **et pousse vers Supabase profiles** pour que les autres
  /// devices du même compte le voient au prochain login.
  static Future<void> setPIN(String pin) async {
    if (!_isValidPin(pin)) {
      throw ArgumentError('PIN must be exactly $pinLength digits');
    }
    final salt = _generateSalt();
    final hash = _hash(pin, salt);
    await _storage.write(key: _kSaltKey, value: salt);
    await _storage.write(key: _kHashKey, value: hash);
    await _resetAttempts();
    await _pushToRemote(hash: hash, salt: salt);
  }

  /// Vérifie le PIN. Retourne `true` si correct.
  /// Incrémente le compteur en cas d'échec ; déclenche le verrou après
  /// [maxAttempts]. Réinitialise tout en cas de succès.
  /// Retourne `false` immédiatement si le service est verrouillé.
  ///
  /// Si le device n'a pas de cache local (premier login après que le PIN
  /// a été configuré sur un autre device), on hydrate depuis Supabase
  /// avant de vérifier — l'utilisateur tape son PIN et ça marche du
  /// premier coup, sans setup local préalable.
  static Future<bool> verifyPIN(String pin) async {
    if (isLocked()) return false;
    if (!_isValidPin(pin)) {
      await _registerFailure();
      return false;
    }
    var salt = await _storage.read(key: _kSaltKey);
    var stored = await _storage.read(key: _kHashKey);
    if (salt == null || stored == null) {
      // Pas de cache local : hydrate depuis le profil distant
      final hydrated = await _hydrateFromRemote();
      if (!hydrated) return false;
      salt   = await _storage.read(key: _kSaltKey);
      stored = await _storage.read(key: _kHashKey);
      if (salt == null || stored == null) return false;
    }

    final candidate = _hash(pin, salt);
    if (_constantTimeEquals(candidate, stored)) {
      await _resetAttempts();
      return true;
    }
    await _registerFailure();
    return false;
  }

  /// Supprime le PIN local ET sur Supabase profiles. Tous les devices du
  /// compte n'auront plus de PIN à la prochaine sync.
  static Future<void> clearPIN() async {
    try {
      await _storage.delete(key: _kHashKey);
      await _storage.delete(key: _kSaltKey);
    } catch (_) {}
    await _resetAttempts();
    await _pushToRemote(hash: null, salt: null);
  }

  /// Synchronisation explicite à appeler au login : si le PIN est défini
  /// côté Supabase profiles mais absent en local (cas d'un nouveau device),
  /// on cache le hash+sel pour que `hasPIN()` et `verifyPIN()` répondent
  /// instantanément offline ensuite.
  ///
  /// Idempotente : ne fait rien si le local a déjà une valeur cohérente.
  static Future<void> hydrateOnLogin() async {
    try {
      final localHash = await _storage.read(key: _kHashKey);
      if (localHash != null && localHash.isNotEmpty) return;
      await _hydrateFromRemote();
    } catch (e) {
      debugPrint('[PinService] hydrateOnLogin: $e');
    }
  }

  // ── Internes Supabase ────────────────────────────────────────────────────

  /// Pull le hash+sel depuis profiles et cache localement. Retourne true
  /// si un PIN existe côté serveur.
  static Future<bool> _hydrateFromRemote() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return false;
    try {
      final row = await Supabase.instance.client
          .from('profiles')
          .select('pin_hash, pin_salt')
          .eq('id', user.id)
          .maybeSingle()
          .timeout(const Duration(seconds: 6));
      final hash = row?['pin_hash'] as String?;
      final salt = row?['pin_salt'] as String?;
      if (hash == null || hash.isEmpty || salt == null || salt.isEmpty) {
        return false;
      }
      await _storage.write(key: _kHashKey, value: hash);
      await _storage.write(key: _kSaltKey, value: salt);
      debugPrint('[PinService] hydrated from remote profile');
      return true;
    } catch (e) {
      debugPrint('[PinService] _hydrateFromRemote: $e');
      return false;
    }
  }

  /// Pousse le hash+sel vers profiles. `null` partout = clearPIN distant.
  static Future<void> _pushToRemote({
    required String? hash,
    required String? salt,
  }) async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;
    try {
      await Supabase.instance.client
          .from('profiles')
          .update({'pin_hash': hash, 'pin_salt': salt})
          .eq('id', user.id)
          .timeout(const Duration(seconds: 6));
    } catch (e) {
      // Best effort : si offline, le PIN reste local. Une prochaine
      // session online pourra appeler `_pushToRemote` via setPIN à
      // nouveau si nécessaire.
      debugPrint('[PinService] _pushToRemote: $e');
    }
  }

  /// Date à laquelle le verrou expire, ou `null` si non verrouillé.
  static DateTime? lockUntil() {
    final raw = HiveBoxes.settingsBox.get(_kLockUntilKey) as String?;
    if (raw == null || raw.isEmpty) return null;
    final dt = DateTime.tryParse(raw);
    if (dt == null) return null;
    if (DateTime.now().isAfter(dt)) return null;
    return dt;
  }

  /// Vrai si le PIN est actuellement verrouillé suite à des échecs répétés.
  static bool isLocked() => lockUntil() != null;

  /// Tentatives restantes avant verrouillage. `maxAttempts` si rien n'a
  /// encore échoué.
  static int attemptsRemaining() {
    final used = (HiveBoxes.settingsBox.get(_kAttemptsKey) as int?) ?? 0;
    final remaining = maxAttempts - used;
    return remaining < 0 ? 0 : remaining;
  }

  // ── Internes ─────────────────────────────────────────────────────────────

  static bool _isValidPin(String pin) =>
      pin.length == pinLength && RegExp(r'^\d+$').hasMatch(pin);

  static String _generateSalt() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    return base64Url.encode(bytes);
  }

  static String _hash(String pin, String salt) {
    final bytes = utf8.encode('$salt:$pin');
    return sha256.convert(bytes).toString();
  }

  /// Comparaison à temps constant pour éviter les attaques par chronométrage.
  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  static Future<void> _registerFailure() async {
    final used = (HiveBoxes.settingsBox.get(_kAttemptsKey) as int?) ?? 0;
    final next = used + 1;
    if (next >= maxAttempts) {
      final until = DateTime.now().add(lockDuration);
      await HiveBoxes.settingsBox.put(_kLockUntilKey, until.toIso8601String());
      await HiveBoxes.settingsBox.put(_kAttemptsKey, next);
    } else {
      await HiveBoxes.settingsBox.put(_kAttemptsKey, next);
    }
  }

  static Future<void> _resetAttempts() async {
    await HiveBoxes.settingsBox.delete(_kAttemptsKey);
    await HiveBoxes.settingsBox.delete(_kLockUntilKey);
  }
}
