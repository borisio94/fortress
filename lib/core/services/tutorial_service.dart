import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persistance « tutoriel vu / non vu ».
///
/// Device-scoped, aligné sur la convention d'[OnboardingPrefs] : toutes les
/// clés sont préfixées `onboarding_` (ici `onboarding_tut_<key>`). On ne crée
/// donc PAS un namespace `tut_` séparé — les flags restent groupés et
/// nettoyables avec le reste de l'onboarding.
class TutorialService {
  TutorialService._();

  static const String _prefix = 'onboarding_tut_';

  /// True si le tutoriel [key] (ex. 'tut_03') a déjà été lancé jusqu'au bout
  /// ou passé.
  static Future<bool> isSeen(String key) async {
    try {
      final p = await SharedPreferences.getInstance();
      return p.getBool('$_prefix$key') ?? false;
    } catch (e) {
      debugPrint('[Tutorial] isSeen err: $e');
      return false;
    }
  }

  static Future<void> markSeen(String key) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool('$_prefix$key', true);
    } catch (e) {
      debugPrint('[Tutorial] markSeen err: $e');
    }
  }

  static Future<void> reset(String key) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove('$_prefix$key');
    } catch (e) {
      debugPrint('[Tutorial] reset err: $e');
    }
  }

  /// Réinitialise TOUS les tutoriels (toutes les clés `onboarding_tut_*`).
  static Future<void> resetAll() async {
    try {
      final p = await SharedPreferences.getInstance();
      final keys = p.getKeys().where((k) => k.startsWith(_prefix)).toList();
      for (final k in keys) {
        await p.remove(k);
      }
    } catch (e) {
      debugPrint('[Tutorial] resetAll err: $e');
    }
  }
}
