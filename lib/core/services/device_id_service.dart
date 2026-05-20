import 'dart:io' show Platform;
import 'dart:math';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import '../storage/hive_boxes.dart';

/// Identifiant stable du device courant — généré au 1er boot et persisté
/// dans la `settingsBox` Hive. Sur web, chaque navigateur (sur chaque profil)
/// est traité comme un device distinct ; effacer les données du site
/// régénère un nouvel ID (= nouveau device aux yeux du backend).
class DeviceIdService {
  static const _key = 'device_id';

  /// Retourne l'ID existant ou en crée un nouveau (UUID v4).
  static String getOrCreate() {
    try {
      final existing = HiveBoxes.settingsBox.get(_key) as String?;
      if (existing != null && existing.isNotEmpty) return existing;
    } catch (e) {
      debugPrint('[DeviceId] read error: $e');
    }
    final fresh = _generateUuidV4();
    try {
      HiveBoxes.settingsBox.put(_key, fresh);
    } catch (e) {
      debugPrint('[DeviceId] persist error: $e');
    }
    return fresh;
  }

  /// Identifiant plateforme — utilisé pour afficher l'icône de la session.
  static String platform() {
    if (kIsWeb) return 'web';
    try {
      if (Platform.isAndroid) return 'android';
      if (Platform.isIOS)     return 'ios';
      if (Platform.isWindows) return 'windows';
      if (Platform.isMacOS)   return 'macos';
      if (Platform.isLinux)   return 'linux';
    } catch (_) {}
    return 'unknown';
  }

  // UUID v4 RFC 4122 — pas besoin d'une lib pour cette unique utilisation.
  static String _generateUuidV4() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    bytes[6] = (bytes[6] & 0x0F) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3F) | 0x80; // variant 10
    String hex(int i) => i.toRadixString(16).padLeft(2, '0');
    final b = bytes.map(hex).join();
    return '${b.substring(0, 8)}-${b.substring(8, 12)}-${b.substring(12, 16)}-'
           '${b.substring(16, 20)}-${b.substring(20, 32)}';
  }
}
