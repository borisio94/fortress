// Implémentation web — manipulation favicon + document.title.
// Importée via conditional import depuis `favicon_blinker.dart`.

// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:async';
// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;

import 'package:flutter/foundation.dart';

/// Clignotement favicon + flashing du titre quand l'onglet n'a pas le focus.
///
/// Usage :
///   ```dart
///   FaviconBlinker.start(flashPrefix: '⚠ COMMANDE — ', suffix: 'Marie');
///   // ... plus tard ...
///   FaviconBlinker.stop();
///   ```
///
/// Comportement :
///   * Favicon : alterne `/favicon.png` ↔ `/favicon-alert.png` toutes 800 ms.
///   * Title  : alterne `'<flashPrefix><suffix>'` ↔ titre original toutes
///     1500 ms, **uniquement quand `!document.hasFocus()`**. Si l'opérateur
///     revient sur l'onglet, le titre original est restauré immédiatement.
///
/// Idempotent : appeler `start()` plusieurs fois ne crée qu'un seul timer.
/// Les paramètres sont mis à jour à chaud (utile si une nouvelle commande
/// urgente arrive avec un autre nom).
class FaviconBlinker {
  FaviconBlinker._();

  static Timer? _faviconTimer;
  static Timer? _titleTimer;
  static bool   _faviconAlt = false;
  static bool   _titleAlt   = false;

  static String _originalTitle = '';
  static String _originalHref  = '';
  static String _flashPrefix   = '';
  static String _suffix        = '';

  static const String _alertFavicon = 'favicon-alert.png';

  static void start({required String flashPrefix, required String suffix}) {
    _flashPrefix = flashPrefix;
    _suffix      = suffix;
    if (_faviconTimer != null) {
      // Déjà actif — on a juste mis à jour les paramètres, le prochain tick
      // les utilisera. Pas besoin de redémarrer les Timer.
      return;
    }
    try {
      _originalTitle = html.document.title;
      final link = _faviconLink();
      _originalHref = link?.href ?? '/favicon.png';
    } catch (e) {
      debugPrint('[FaviconBlinker] init capture failed: $e');
    }

    // Favicon : alterne toutes les 800 ms tant qu'actif (peu importe le focus
    // — les onglets en arrière-plan affichent le favicon dans la barre).
    _faviconTimer = Timer.periodic(const Duration(milliseconds: 800), (_) {
      _faviconAlt = !_faviconAlt;
      _setFavicon(_faviconAlt ? _alertFavicon : _originalHref);
    });

    // Title : alterne toutes les 1500 ms UNIQUEMENT si l'onglet n'est pas
    // visible (Page Visibility API — plus permissif que hasFocus mais
    // couvre le cas demandé : "utilisateur sur un autre onglet"). Quand
    // l'utilisateur revient, on restaure le titre original immédiatement.
    _titleTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      try {
        final hidden = html.document.hidden ?? false;
        if (hidden) {
          _titleAlt = !_titleAlt;
          html.document.title = _titleAlt
              ? '$_flashPrefix$_suffix'
              : _originalTitle;
        } else if (html.document.title != _originalTitle) {
          html.document.title = _originalTitle;
        }
      } catch (e) {
        debugPrint('[FaviconBlinker] title tick failed: $e');
      }
    });

    debugPrint('[FaviconBlinker] start (suffix="$suffix")');
  }

  static void stop() {
    _faviconTimer?.cancel();
    _faviconTimer = null;
    _titleTimer?.cancel();
    _titleTimer = null;
    try {
      if (_originalHref.isNotEmpty) _setFavicon(_originalHref);
      if (_originalTitle.isNotEmpty) html.document.title = _originalTitle;
    } catch (e) {
      debugPrint('[FaviconBlinker] restore failed: $e');
    }
    _faviconAlt = false;
    _titleAlt   = false;
    debugPrint('[FaviconBlinker] stop');
  }

  static html.LinkElement? _faviconLink() {
    final list = html.document.querySelectorAll('link[rel="icon"]');
    if (list.isEmpty) return null;
    return list.first as html.LinkElement;
  }

  static void _setFavicon(String href) {
    try {
      final link = _faviconLink();
      if (link != null) {
        link.href = href;
      } else {
        // Pas de balise existante → on l'injecte. Cas rare mais prévu (le
        // template web/index.html devrait toujours en avoir une).
        final inj = html.LinkElement()
          ..rel  = 'icon'
          ..type = 'image/png'
          ..href = href;
        html.document.head?.append(inj);
      }
    } catch (e) {
      debugPrint('[FaviconBlinker] setFavicon failed: $e');
    }
  }
}
