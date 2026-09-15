import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../database/app_database.dart';

/// Phase 1 observabilité — point d'entrée unique de remontée des bugs.
///
/// Rôle : enrichir + envoyer chaque erreur à DEUX destinations :
///   • Sentry (forensics complet) — pour les captures MANUELLES ;
///   • la table Supabase `error_reports` (RPC `report_error`, dédupliquée
///     côté serveur) → visible dans le dashboard SA, offline-first via la
///     file d'attente existante.
///
/// L'observabilité ne doit JAMAIS faire planter l'app : tout est protégé.
class ErrorReporter {
  ErrorReporter._();

  /// Route courante (cible « écran »). Mise à jour par le router à chaque
  /// navigation (cf. app_router redirect). Sert aussi à extraire `shop_id`.
  static String? lastRoute;

  static String get _platform {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android: return 'android';
      case TargetPlatform.iOS:     return 'ios';
      default: return defaultTargetPlatform.name;
    }
  }

  static String? _shopFromRoute(String? route) {
    if (route == null) return null;
    final m = RegExp(r'/shop/([^/]+)').firstMatch(route);
    return m?.group(1);
  }

  /// Bruit réseau / transitoire : reste dans Sentry mais NE remplit PAS
  /// `error_reports` (sinon le SA est noyé par des erreurs de connexion
  /// bénignes, normales en POS offline-first).
  static bool _isBenign(Object error) {
    final s = error.toString().toLowerCase();
    return s.contains('socketexception')
        || s.contains('clientexception')
        || s.contains('timeoutexception')
        || s.contains('failed host lookup')
        || s.contains('connection closed')
        || s.contains('connection refused')
        || s.contains('connection reset')
        || s.contains('network is unreachable')
        || s.contains('xmlhttprequest error')
        || s.contains('handshakeexception');
  }

  /// Capture MANUELLE depuis un `catch` métier critique (Phase 2).
  /// Envoie à Sentry ET à `error_reports`.
  static void capture(
    Object error,
    StackTrace? stack, {
    String severity = 'error',
    String? action,
    Map<String, dynamic>? context,
  }) =>
      _report(error, stack,
          severity: severity,
          action: action,
          context: context,
          sendToSentry: true);

  /// Depuis `FlutterError.onError` (erreur de build/widget). Sentry l'a DÉJÀ
  /// captée via son binding → on ne re-poste pas à Sentry, on alimente juste
  /// `error_reports`.
  static void fromFlutterError(FlutterErrorDetails details) =>
      _report(details.exception, details.stack,
          severity: 'error',
          action: details.context?.toString(),
          sendToSentry: false);

  /// Depuis `PlatformDispatcher.onError` (exception async non catchée → fatal).
  static void fromZoneError(Object error, StackTrace stack) =>
      _report(error, stack, severity: 'fatal', sendToSentry: false);

  static void _report(
    Object error,
    StackTrace? stack, {
    required String severity,
    String? action,
    Map<String, dynamic>? context,
    required bool sendToSentry,
  }) {
    try {
      if (_isBenign(error)) return;
      if (sendToSentry) {
        unawaited(Sentry.captureException(error, stackTrace: stack));
      }
      final route = lastRoute;
      final params = <String, dynamic>{
        'p_severity':    severity,
        'p_error_type':  error.runtimeType.toString(),
        'p_message':     error.toString(),
        'p_stack':       stack?.toString(),
        'p_route':       route,
        'p_action':      action,
        'p_shop_id':     _shopFromRoute(route),
        'p_platform':    _platform,
        'p_context':     context,
      };
      unawaited(AppDatabase.reportError(params));
    } catch (_) {
      // L'observabilité ne casse jamais l'app.
    }
  }
}
