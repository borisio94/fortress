import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../storage/hive_boxes.dart';

/// Mode démo : quand actif, un overlay dessine un cercle/ripple à chaque
/// appui pour que les interactions soient visibles dans une vidéo
/// d'enregistrement d'écran (utile sur iOS où il n'existe pas d'option
/// système « Afficher les touches »).
final demoModeProvider =
    NotifierProvider<DemoModeNotifier, bool>(DemoModeNotifier.new);

class DemoModeNotifier extends Notifier<bool> {
  static const _key = 'demo_mode_enabled';

  @override
  bool build() => _readFromHive();

  bool _readFromHive() {
    try {
      if (!Hive.isBoxOpen(HiveBoxes.settings)) return false;
      return HiveBoxes.settingsBox.get(_key) == true;
    } catch (e) {
      debugPrint('[DemoMode] read error: $e');
      return false;
    }
  }

  Future<void> setEnabled(bool enabled) async {
    if (state == enabled) return;
    state = enabled;
    try {
      await HiveBoxes.settingsBox.put(_key, enabled);
    } catch (e) {
      debugPrint('[DemoMode] persist error: $e');
    }
  }

  Future<void> toggle() => setEnabled(!state);
}
