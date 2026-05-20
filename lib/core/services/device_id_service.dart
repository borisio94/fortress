import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import '../storage/hive_boxes.dart';
import '../utils/uuid.dart';

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
    final fresh = Uuid.v4();
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

}
