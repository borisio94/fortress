import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../../../core/services/scheduled_order_alert_service.dart' show AlertLevel;
import '../../../core/storage/hive_boxes.dart';

/// Lecteur de sons d'alerte pour les commandes programmées.
///
/// **Web** : les navigateurs bloquent l'autoplay tant que l'utilisateur n'a
/// pas interagi (clic / touche). On expose [unlock] qui doit être appelé
/// depuis un listener click global au boot (cf. main.dart). Tant que
/// `_unlocked == false`, [playAlarm] log un avertissement et no-op
/// gracieusement (l'UI sprint 2 affichera un toast "cliquez pour activer
/// les sons").
///
/// **Mobile / desktop natif** : pas de verrou — [playAlarm] joue directement.
///
/// Volume : lu depuis `settings_box['alert_volume']` (0.0..1.0). Défaut 0.7.
class AlarmSoundPlayer {
  AlarmSoundPlayer._();
  static final AlarmSoundPlayer instance = AlarmSoundPlayer._();

  /// 3 sons distincts. Soft = J-1 (info), Medium = H-2 (warning),
  /// Strong = H-1 et plus grave (critical / criticalRepeat / max / overdue).
  static const String _assetSoft   = 'sounds/alarm_soft.mp3';
  static const String _assetMedium = 'sounds/alarm_medium.mp3';
  static const String _assetStrong = 'sounds/alarm_strong.mp3';

  /// Une seule instance d'AudioPlayer suffit pour notre usage : on ne joue
  /// jamais plus d'un son en même temps. Releaser l'ancien clip si on doit
  /// jouer le suivant (mode `ReleaseMode.stop`).
  ///
  /// Lazy + nullable + try/catch : sur Flutter web, certaines versions
  /// d'audioplayers échouent à enregistrer le canal `global/events`
  /// (`MissingPluginException`) au moment de l'instanciation. On évite
  /// d'appeler le constructeur au boot du singleton — il est créé à la
  /// demande, et toute erreur d'init est avalée silencieusement (le son
  /// devient juste un no-op au lieu de crasher le flux appelant).
  AudioPlayer? _player;
  bool _playerInitFailed = false;
  bool _unlocked = !kIsWeb; // sur natif, pas de verrou

  AudioPlayer? _getPlayer() {
    if (_player != null) return _player;
    if (_playerInitFailed) return null;
    try {
      _player = AudioPlayer();
      return _player;
    } catch (e) {
      _playerInitFailed = true;
      debugPrint('[AlarmSound] AudioPlayer init failed: $e');
      return null;
    }
  }

  /// À appeler une seule fois après la 1ʳᵉ interaction utilisateur sur web
  /// (cf. listener pointer/keyboard global dans main.dart). Sans ça, le
  /// navigateur refuse de jouer un son issu d'un Timer.
  Future<void> unlock() async {
    if (_unlocked) return;
    final player = _getPlayer();
    if (player == null) {
      // Plugin audio indisponible (web sans support). On considère
      // l'AudioContext comme « déverrouillé » pour ne pas spammer
      // les retry — playAlarm fera un no-op silencieux de toute façon.
      _unlocked = true;
      return;
    }
    try {
      // Astuce : un play volume=0 sur un asset trivial "déverrouille" le
      // contexte audio web. Si ça échoue (asset pas chargé), on retentera
      // au prochain clic via le listener global qui appelle unlock() en
      // boucle (idempotent grâce au flag).
      await player.setVolume(0);
      await player.play(AssetSource(_assetSoft));
      await player.stop();
      _unlocked = true;
      debugPrint('[AlarmSound] AudioContext unlocked');
    } catch (e) {
      debugPrint('[AlarmSound] unlock failed (retry au prochain clic): $e');
    }
  }

  /// Joue le son correspondant au niveau d'alerte. Sur web non-unlocké :
  /// no-op + debugPrint. Idempotent — pas d'effet de bord si l'app est
  /// inactive (audioplayers gère l'arrêt propre).
  Future<void> playAlarm(AlertLevel level) async {
    if (!_unlocked) {
      debugPrint('[AlarmSound] skip ${level.name} — AudioContext verrouillé '
          '(en attente d\'un clic utilisateur)');
      return;
    }
    final player = _getPlayer();
    if (player == null) return; // plugin indisponible
    final asset = _assetForLevel(level);
    final volume = _readVolume();
    try {
      await player.stop(); // libère le clip précédent
      await player.setReleaseMode(ReleaseMode.stop);
      await player.setVolume(volume);
      await player.play(AssetSource(asset));
      debugPrint('[AlarmSound] play ${level.name} '
          '($asset, vol=${volume.toStringAsFixed(2)})');
    } catch (e) {
      debugPrint('[AlarmSound] play failed for ${level.name}: $e');
    }
  }

  /// Stoppe immédiatement le son en cours. Utile pour la modale UI sprint 2
  /// qui voudra couper le permanent `max` quand l'opérateur acquitte.
  Future<void> stop() async {
    try {
      await _player?.stop();
    } catch (_) {/* best effort */}
  }

  String _assetForLevel(AlertLevel level) {
    switch (level) {
      case AlertLevel.info:
        return _assetSoft;
      case AlertLevel.warning:
        return _assetMedium;
      case AlertLevel.critical:
      case AlertLevel.criticalRepeat:
      case AlertLevel.max:
      case AlertLevel.overdue:
        return _assetStrong;
    }
  }

  double _readVolume() {
    try {
      final raw = HiveBoxes.settingsBox.get('alert_volume');
      if (raw is num) {
        final v = raw.toDouble();
        if (v >= 0 && v <= 1) return v;
      }
    } catch (_) {/* settings pas prêts → défaut */}
    return 0.7;
  }
}
