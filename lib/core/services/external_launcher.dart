import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:url_launcher/url_launcher.dart';

import 'web_window.dart'
    if (dart.library.html) 'web_window_web.dart';

/// Ouvre une URL externe (typiquement `wa.me/...`) en bypass-ant les
/// popup blockers du navigateur sur web.
///
/// **Critique pour WhatsApp sur Flutter web** : `url_launcher` fait un
/// round-trip via method channel qui rompt le user gesture. Le navigateur
/// bloque alors silencieusement la nouvelle fenêtre. On contourne en
/// appelant `window.open(url)` directement (synchrone) sur web. Sur
/// mobile / desktop natif, on garde `url_launcher` qui ouvre l'app
/// installée.
///
/// **Doit être appelé DANS LE MÊME TICK que le clic utilisateur** —
/// pas après un `await`.
Future<bool> openExternal(String url) async {
  if (kIsWeb) {
    // Tentative directe via `window.open` — synchrone, conserve le
    // user gesture. Pas d'await Dart avant cet appel côté caller.
    final ok = openInNewTab(url);
    if (ok) return true;
    debugPrint('[Launcher] window.open returned null (popup blocked?) — '
        'fallback url_launcher');
  }
  try {
    final mode = kIsWeb
        ? LaunchMode.platformDefault
        : LaunchMode.externalApplication;
    final ok = await launchUrl(Uri.parse(url), mode: mode);
    if (!ok) debugPrint('[Launcher] launchUrl returned false: $url');
    return ok;
  } catch (e) {
    debugPrint('[Launcher] error: $e');
    return false;
  }
}
