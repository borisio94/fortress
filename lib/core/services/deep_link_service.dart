import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Deep-link bridge — reçoit les URI entrantes et les pousse vers GoRouter.
// Schemes gérés :
//   • https://stately-sunshine-3593ef.netlify.app/accept-invite?token=… → /accept-invite
//
// Lancer init(router) UNE fois depuis PosApp.initState après la création du
// router, pour avoir accès à l'instance GoRouter.
// ─────────────────────────────────────────────────────────────────────────────

class DeepLinkService {
  static final _appLinks = AppLinks();
  static StreamSubscription<Uri>? _sub;

  static Future<void> init(GoRouter router) async {
    // 1. Lien initial (app lancée depuis le lien)
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) _handle(initial, router);
    } catch (e) {
      debugPrint('[DeepLink] initial error: $e');
    }

    // 2. Liens reçus pendant que l'app tourne
    _sub?.cancel();
    _sub = _appLinks.uriLinkStream.listen(
      (uri) => _handle(uri, router),
      onError: (e) => debugPrint('[DeepLink] stream error: $e'),
    );
  }

  static void dispose() {
    _sub?.cancel();
    _sub = null;
  }

  static void _handle(Uri uri, GoRouter router) {
    debugPrint('[DeepLink] reçu: $uri');

    // https://stately-sunshine-3593ef.netlify.app/accept-invite?token=…
    if (uri.host == 'stately-sunshine-3593ef.netlify.app') {
      final path = uri.path.isEmpty ? '/' : uri.path;
      router.go('$path${uri.hasQuery ? '?${uri.query}' : ''}');
      return;
    }

    // Fallback : tente de router directement par path
    if (uri.path.isNotEmpty && uri.path != '/') {
      router.go('${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}');
    }
  }
}
