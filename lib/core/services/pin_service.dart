import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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

  /// Vrai si un PIN propriétaire a déjà été enregistré sur ce device.
  static Future<bool> hasPIN() async {
    try {
      final hash = await _storage.read(key: _kHashKey);
      return hash != null && hash.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Enregistre (ou remplace) le PIN. Génère un nouveau sel et réinitialise
  /// le compteur de tentatives.
  static Future<void> setPIN(String pin) async {
    if (!_isValidPin(pin)) {
      throw ArgumentError('PIN must be exactly $pinLength digits');
    }
    final salt = _generateSalt();
    final hash = _hash(pin, salt);
    await _storage.write(key: _kSaltKey, value: salt);
    await _storage.write(key: _kHashKey, value: hash);
    await _resetAttempts();
  }

  /// Vérifie le PIN. Retourne `true` si correct.
  /// Incrémente le compteur en cas d'échec ; déclenche le verrou après
  /// [maxAttempts]. Réinitialise tout en cas de succès.
  /// Retourne `false` immédiatement si le service est verrouillé.
  static Future<bool> verifyPIN(String pin) async {
    if (isLocked()) return false;
    if (!_isValidPin(pin)) {
      await _registerFailure();
      return false;
    }
    final salt = await _storage.read(key: _kSaltKey);
    final stored = await _storage.read(key: _kHashKey);
    if (salt == null || stored == null) return false;

    final candidate = _hash(pin, salt);
    if (_constantTimeEquals(candidate, stored)) {
      await _resetAttempts();
      return true;
    }
    await _registerFailure();
    return false;
  }

  /// Supprime le PIN et toutes les métadonnées associées.
  static Future<void> clearPIN() async {
    try {
      await _storage.delete(key: _kHashKey);
      await _storage.delete(key: _kSaltKey);
    } catch (_) {}
    await _resetAttempts();
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
