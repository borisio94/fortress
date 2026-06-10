import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../storage/hive_boxes.dart';

/// Clé Hive de la taille de texte choisie par l'utilisateur.
const String kTextScaleKey = 'text_scale';

/// Facteur multiplicateur de la taille du texte de TOUTE l'app, réglable par
/// l'utilisateur (Paramètres → Taille du texte). Appliqué dans `PosApp` via le
/// `textScaler` du MediaQuery : tout le texte se redimensionne en direct quand
/// la valeur change (aperçu instantané pendant le glissement du curseur).
final textScaleProvider =
    NotifierProvider<TextScaleNotifier, double>(TextScaleNotifier.new);

class TextScaleNotifier extends Notifier<double> {
  static const double minScale = 0.9;
  static const double maxScale = 1.6;
  static const double defaultScale = 1.25; // = ancien réglage figé (+25 %)

  @override
  double build() {
    try {
      if (!Hive.isBoxOpen(HiveBoxes.settings)) return defaultScale;
      final v = HiveBoxes.settingsBox.get(kTextScaleKey);
      final f = (v is num) ? v.toDouble() : defaultScale;
      return f.clamp(minScale, maxScale).toDouble();
    } catch (e) {
      debugPrint('[TextScale] read error: $e');
      return defaultScale;
    }
  }

  /// Aperçu EN DIRECT pendant le glissement du curseur (ne persiste pas).
  void preview(double v) => state = v.clamp(minScale, maxScale).toDouble();

  /// Enregistre la valeur (au relâchement du curseur).
  Future<void> commit(double v) async {
    final c = v.clamp(minScale, maxScale).toDouble();
    state = c;
    try {
      await HiveBoxes.settingsBox.put(kTextScaleKey, c);
    } catch (e) {
      debugPrint('[TextScale] persist error: $e');
    }
  }

  Future<void> reset() => commit(defaultScale);
}
