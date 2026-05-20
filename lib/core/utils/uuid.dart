import 'dart:math';

/// UUID v4 RFC 4122 — `Random.secure()` (CSPRNG), pas de dépendance externe.
///
/// Utilisé partout où on a besoin d'une clé d'idempotence ou d'un identifiant
/// stable côté client : ventes (GF-1), transferts (GF-2), device IDs, etc.
/// 128 bits d'entropie — collisions négligeables même à très haut débit.
class Uuid {
  Uuid._();

  static final _rng = Random.secure();

  /// Génère un UUID v4 au format canonique `xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx`
  /// (36 caractères, lowercase).
  static String v4() {
    final bytes = List<int>.generate(16, (_) => _rng.nextInt(256));
    bytes[6] = (bytes[6] & 0x0F) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3F) | 0x80; // variant 10
    String hex(int i) => i.toRadixString(16).padLeft(2, '0');
    final b = bytes.map(hex).join();
    return '${b.substring(0, 8)}-${b.substring(8, 12)}-${b.substring(12, 16)}-'
           '${b.substring(16, 20)}-${b.substring(20, 32)}';
  }
}
