import 'dart:async';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'device_id_service.dart';

/// Modèle léger pour la liste des sessions actives.
class ActiveSession {
  final String id;
  final String deviceId;
  final String? platform;
  final String? userAgent;
  final DateTime lastSeen;
  final DateTime createdAt;

  const ActiveSession({
    required this.id,
    required this.deviceId,
    required this.platform,
    required this.userAgent,
    required this.lastSeen,
    required this.createdAt,
  });

  factory ActiveSession.fromMap(Map<String, dynamic> m) => ActiveSession(
        id:         m['id']         as String,
        deviceId:   m['device_id']  as String,
        platform:   m['platform']   as String?,
        userAgent:  m['user_agent'] as String?,
        lastSeen:   DateTime.parse(m['last_seen']  as String).toLocal(),
        createdAt:  DateTime.parse(m['created_at'] as String).toLocal(),
      );

  bool get isCurrent => deviceId == DeviceIdService.getOrCreate();
}

/// Gère la session courante côté client : enregistrement au login,
/// heartbeat toutes les 5 min, écoute realtime pour soft-kick.
///
/// Usage :
///   - `await SessionService.register()` au login (et au check de session
///     restaurée au boot).
///   - `SessionService.start(onKicked: ...)` une fois authentifié — démarre
///     heartbeat + listener.
///   - `SessionService.stop()` au logout.
///   - `SessionService.revokeCurrent()` lors d'un logout volontaire.
class SessionService {
  static SupabaseClient get _sb => Supabase.instance.client;

  // Period heartbeat — 5 min côté client, suffit largement vs cleanup
  // backend à 30 min d'inactivité.
  static const _heartbeatPeriod = Duration(minutes: 5);

  static Timer?               _heartbeatTimer;
  static RealtimeChannel?     _channel;
  static VoidCallback?        _onKicked;
  static bool                 _started = false;

  /// Enregistre / met à jour la session courante côté Supabase. Appelle
  /// le RPC `register_session` qui upsert + cleanup les sessions excédant
  /// la limite (selon rôle).
  static Future<void> register() async {
    if (_sb.auth.currentUser == null) return;
    try {
      await _sb.rpc('register_session', params: {
        'p_device_id':  DeviceIdService.getOrCreate(),
        'p_platform':   DeviceIdService.platform(),
        'p_user_agent': _userAgent(),
      });
    } catch (e) {
      debugPrint('[Session] register error: $e');
    }
  }

  /// Démarre le heartbeat + l'écoute realtime. Idempotent — `stop()`
  /// d'abord si déjà démarré.
  static void start({VoidCallback? onKicked}) {
    if (_started) return;
    _started = true;
    _onKicked = onKicked;

    // 1) Heartbeat périodique.
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_heartbeatPeriod, (_) => _heartbeat());

    // 2) Realtime : écoute la suppression/update de la session courante.
    //    Si la row du device courant disparaît → l'utilisateur est kické.
    final uid = _sb.auth.currentUser?.id;
    if (uid != null) {
      try {
        _channel?.unsubscribe();
        _channel = _sb.channel('active_sessions:$uid')
          ..onPostgresChanges(
            event:  PostgresChangeEvent.delete,
            schema: 'public',
            table:  'active_sessions',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'user_id',
              value: uid,
            ),
            callback: _onDelete,
          )
          ..subscribe();
      } catch (e) {
        debugPrint('[Session] realtime subscribe error: $e');
      }
    }
  }

  /// Stoppe heartbeat + listener. À appeler au logout.
  static void stop() {
    _started = false;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    try {
      _channel?.unsubscribe();
    } catch (_) {}
    _channel = null;
    _onKicked = null;
  }

  /// Révoque la session courante (logout volontaire).
  static Future<void> revokeCurrent() async {
    if (_sb.auth.currentUser == null) return;
    try {
      await _sb.rpc('revoke_session', params: {
        'p_device_id': DeviceIdService.getOrCreate(),
      });
    } catch (e) {
      debugPrint('[Session] revokeCurrent error: $e');
    }
  }

  /// Révoque toutes les sessions sauf la courante.
  static Future<int> revokeOthers() async {
    try {
      final res = await _sb.rpc('revoke_other_sessions', params: {
        'p_keep_device_id': DeviceIdService.getOrCreate(),
      });
      return (res as int?) ?? 0;
    } catch (e) {
      debugPrint('[Session] revokeOthers error: $e');
      return 0;
    }
  }

  /// Liste les sessions actives de l'utilisateur courant.
  static Future<List<ActiveSession>> list() async {
    try {
      final res = await _sb.rpc('list_my_sessions');
      if (res is! List) return const [];
      return res
          .whereType<Map>()
          .map((m) => ActiveSession.fromMap(Map<String, dynamic>.from(m)))
          .toList();
    } catch (e) {
      debugPrint('[Session] list error: $e');
      return const [];
    }
  }

  // ─── Internes ─────────────────────────────────────────────────────────────

  static Future<void> _heartbeat() async {
    if (_sb.auth.currentUser == null) return;
    try {
      final ok = await _sb.rpc('heartbeat_session', params: {
        'p_device_id': DeviceIdService.getOrCreate(),
      });
      // Si la RPC retourne false, ma session n'existe plus côté serveur :
      // on déclenche le kick comme si on avait reçu l'évènement realtime.
      if (ok == false) _triggerKick();
    } catch (e) {
      debugPrint('[Session] heartbeat error: $e');
    }
  }

  static void _onDelete(PostgresChangePayload payload) {
    final old = payload.oldRecord;
    final myDeviceId = DeviceIdService.getOrCreate();
    if (old['device_id'] == myDeviceId) {
      _triggerKick();
    }
  }

  static void _triggerKick() {
    final cb = _onKicked;
    if (cb != null) {
      cb();
    }
    // Stop pour ne pas réémettre.
    stop();
  }

  static String? _userAgent() {
    if (kIsWeb) {
      // Sur web, on lit `navigator.userAgent` via un import conditionnel.
      // Pour rester simple ici (pas de fichier conditionnel), on retourne
      // null — la plateforme 'web' suffit déjà à identifier la session.
      return null;
    }
    return null;
  }
}

typedef VoidCallback = void Function();
