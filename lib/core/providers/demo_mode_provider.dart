import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../storage/hive_boxes.dart';

/// Clé Hive du mode démo.
const String kDemoModeKey = 'demo_mode_enabled';

/// Mode démo : quand actif, un repère (cercle) marque CHAQUE appui à l'écran,
/// exactement où l'on touche (cf. `DemoTapIndicator`), pour les
/// enregistrements vidéo (montrer quelle action déclenche quel résultat). Le
/// ripple Material est aussi amplifié (sur-thème dans PosApp).
final demoModeProvider =
    NotifierProvider<DemoModeNotifier, bool>(DemoModeNotifier.new);

class DemoModeNotifier extends Notifier<bool> {
  @override
  bool build() => DemoMode.isEnabled;

  Future<void> setEnabled(bool enabled) async {
    if (state == enabled) return;
    state = enabled;
    try {
      await HiveBoxes.settingsBox.put(kDemoModeKey, enabled);
    } catch (e) {
      debugPrint('[DemoMode] persist error: $e');
    }
  }

  Future<void> toggle() => setEnabled(!state);
}

/// Accès synchrone au mode démo pour les widgets hors Riverpod.
class DemoMode {
  DemoMode._();

  static bool get isEnabled {
    try {
      if (!Hive.isBoxOpen(HiveBoxes.settings)) return false;
      return HiveBoxes.settingsBox.get(kDemoModeKey) == true;
    } catch (e) {
      debugPrint('[DemoMode] read error: $e');
      return false;
    }
  }
}
