import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../storage/hive_boxes.dart';

/// Mode thème (clair / sombre / système). Persisté dans `settingsBox`.
final themeModeProvider =
    NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);

class ThemeModeNotifier extends Notifier<ThemeMode> {
  static const _key = 'app_theme_mode';

  @override
  ThemeMode build() {
    return _readFromHive();
  }

  ThemeMode _readFromHive() {
    try {
      if (!Hive.isBoxOpen(HiveBoxes.settings)) return ThemeMode.light;
      final raw = HiveBoxes.settingsBox.get(_key);
      switch (raw) {
        case 'dark':
          return ThemeMode.dark;
        case 'system':
          return ThemeMode.system;
        case 'light':
        default:
          return ThemeMode.light;
      }
    } catch (e) {
      debugPrint('[ThemeMode] read error: $e');
      return ThemeMode.light;
    }
  }

  Future<void> setMode(ThemeMode mode) async {
    if (state == mode) return;
    state = mode;
    try {
      await HiveBoxes.settingsBox.put(_key, _serialize(mode));
    } catch (e) {
      debugPrint('[ThemeMode] persist error: $e');
    }
  }

  String _serialize(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.dark:
        return 'dark';
      case ThemeMode.system:
        return 'system';
      case ThemeMode.light:
        return 'light';
    }
  }
}
