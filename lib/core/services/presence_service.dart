import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Service de présence en ligne.
///
/// Met à jour `profiles.last_seen_at` toutes les 60s via la RPC
/// `update_my_last_seen`. Utilisé par `is_owner_online` côté SQL pour
/// bloquer les demandes admin → owner si ce dernier n'est pas connecté.
///
/// Le seuil "online" côté SQL est 90s, donc un ping toutes les 60s laisse
/// une marge de 30s en cas de latence réseau.
class PresenceService {
  static Timer? _timer;
  static const Duration _interval = Duration(seconds: 60);

  /// Démarre les pings périodiques. Appelé après login réussi.
  /// Idempotent : un appel pendant qu'un timer tourne est no-op.
  static void start() {
    if (_timer?.isActive ?? false) return;
    _ping(); // ping immédiat pour ne pas attendre 60s
    _timer = Timer.periodic(_interval, (_) => _ping());
    debugPrint('[Presence] ✅ heartbeat démarré (toutes les ${_interval.inSeconds}s)');
  }

  /// Stoppe les pings. Appelé au logout.
  static void stop() {
    _timer?.cancel();
    _timer = null;
    debugPrint('[Presence] ⊘ heartbeat arrêté');
  }

  static Future<void> _ping() async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) {
      stop();
      return;
    }
    try {
      await Supabase.instance.client.rpc('update_my_last_seen');
    } catch (e) {
      // Erreur silencieuse : si l'app est offline, le ping échoue, c'est OK.
      // Le owner sera juste considéré offline par les autres.
      debugPrint('[Presence] ping échoué : $e');
    }
  }
}
