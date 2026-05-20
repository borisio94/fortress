// Stub mobile / desktop — pas de favicon ni de title navigateur à manipuler.
// La vraie implémentation web vit dans `favicon_blinker_web.dart`, choisie
// via conditional import (cf. consommateur).

/// Statique, web only. Sur natif les méthodes sont des no-op.
///
/// Suit le même pattern que `web_window.dart` ↔ `web_window_web.dart` :
/// le caller importe ce stub par défaut et substitue la version web via
/// `import 'favicon_blinker.dart' if (dart.library.html) 'favicon_blinker_web.dart';`
class FaviconBlinker {
  FaviconBlinker._();

  /// No-op natif.
  // ignore: avoid_unused_constructor_parameters
  static void start({required String flashPrefix, required String suffix}) {}

  /// No-op natif.
  static void stop() {}
}
