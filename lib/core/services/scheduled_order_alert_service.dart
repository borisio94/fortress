import 'dart:async';

import 'package:flutter/foundation.dart';

import '../database/app_database.dart';
import '../storage/hive_boxes.dart';
import 'notification_service.dart';
// import différé pour éviter une dépendance circulaire avec UI :
// AlarmSoundPlayer est sous lib/shared/widgets/alerts/. Le service le
// connaît mais l'UI viendra plus tard (sprint 2). On l'appelle via une
// méthode publique pour garder la couche service indépendante de Flutter
// hors `kIsWeb` / `debugPrint`.
import '../../shared/widgets/alerts/alarm_sound_player.dart';

/// Niveau d'escalade d'une alerte de commande programmée.
///
/// L'ordre de déclaration EST l'ordre de gravité croissante — utilisé pour
/// déterminer le niveau "max atteint et non acquitté" via `index`.
enum AlertLevel {
  /// J-1 à 07h00 — soft, 1 fois.
  info,
  /// H-2 (jour J) — medium, 1 fois.
  warning,
  /// H-1 — strong, 1 fois (3 s).
  critical,
  /// H-30min — strong, répété toutes les 5 min jusqu'à acquittement
  /// (ou jusqu'à passage en `max`).
  criticalRepeat,
  /// H-15min — strong, permanent jusqu'à acquittement OU changement de statut.
  max,
  /// H+0 (dépassée) — strong, 1 fois.
  overdue,
}

/// Snapshot d'une alerte active pour la modale UI (sprint 2).
@immutable
class AlertInfo {
  final String      orderId;
  final String?     shopId;
  final AlertLevel  level;
  final DateTime    scheduledAt;
  final DateTime    triggeredAt;
  final String?     customerName;
  final bool        acknowledged;

  const AlertInfo({
    required this.orderId,
    required this.shopId,
    required this.level,
    required this.scheduledAt,
    required this.triggeredAt,
    required this.customerName,
    required this.acknowledged,
  });

  AlertInfo copyWith({bool? acknowledged}) => AlertInfo(
        orderId:      orderId,
        shopId:       shopId,
        level:        level,
        scheduledAt:  scheduledAt,
        triggeredAt:  triggeredAt,
        customerName: customerName,
        acknowledged: acknowledged ?? this.acknowledged,
      );
}

/// Service singleton qui surveille les commandes `status='scheduled'` et
/// déclenche des alertes sonores + signaux UI escaladés en fonction du delta
/// `scheduledAt - now`. Persiste les acquittements par niveau dans
/// `acknowledged_alerts_box` pour ne pas re-jouer un son déjà confirmé.
///
/// Filtre destinataire : owner/admin uniquement (lit
/// `NotificationService.enabledForCurrentUser`). Le service redémarre
/// automatiquement quand ce flag bascule.
///
/// TODO(timezone): le calcul "J-1 à 07h00" utilise l'offset machine local.
/// Quand `shop.timezone` sera persisté côté boutique, lire ce champ et
/// recalculer dans la timezone de la boutique (utile si l'opérateur est
/// dans un autre fuseau que sa boutique).
class ScheduledOrderAlertService {
  ScheduledOrderAlertService._();
  static final ScheduledOrderAlertService instance =
      ScheduledOrderAlertService._();

  // ── État interne ───────────────────────────────────────────────────────
  Timer? _ticker;
  Timer? _retryStart;
  bool   _started = false;
  bool   _wiredAppDb = false;
  void   Function(String table, String shopId)? _onChanged;
  final  StreamController<List<AlertInfo>> _alertsCtl =
      StreamController<List<AlertInfo>>.broadcast();

  /// Cache des dernières alertes émises par commande+niveau, pour détecter
  /// les transitions et logger une seule ligne par changement de niveau.
  final Map<String, AlertLevel> _lastEmitted = {};

  /// Pour `criticalRepeat` : timestamp du dernier replay sonore par commande.
  final Map<String, DateTime> _lastRepeatPlayed = {};

  /// Anti-doublon : évite de jouer le son `max` plus d'une fois par tick
  /// (le tick fait déjà 30 s, ça suffit pour "permanent").
  final Set<String> _maxPlayedOnce = {};

  /// Flux d'alertes actives (snapshot complet à chaque tick). L'UI sprint 2
  /// fera un `StreamBuilder` dessus pour la modale + le bandeau topbar.
  Stream<List<AlertInfo>> get alerts => _alertsCtl.stream;

  // ══════════════════════════════════════════════════════════════════════
  //  CYCLE DE VIE
  // ══════════════════════════════════════════════════════════════════════

  /// Démarre le service. Idempotent : un second appel est ignoré.
  /// Si `AppDatabase` n'est pas encore prêt (ordersBox pas ouverte), on
  /// retry une seule fois après 2 s avant d'abandonner avec un avertissement.
  Future<void> start() async {
    if (_started) return;
    // Attendre que la box orders soit ouverte (peut arriver tard au boot).
    if (!_isReady()) {
      debugPrint('[ScheduledAlerts] start() : Hive pas prêt, retry dans 2s');
      _retryStart?.cancel();
      _retryStart = Timer(const Duration(seconds: 2), () {
        if (_isReady()) {
          // ignore: discarded_futures
          start();
        } else {
          debugPrint('[ScheduledAlerts] start() : Hive toujours pas prêt '
              'après retry — service désactivé pour cette session');
        }
      });
      return;
    }
    _started = true;
    debugPrint('[ScheduledAlerts] start()');

    // Filtre owner : si l'user courant n'est pas autorisé, on n'arme rien.
    // Le ValueNotifier `enabledForCurrentUser` est écouté juste après pour
    // (re)démarrer dynamiquement quand le rôle change (login, switch shop).
    NotificationService.enabledForCurrentUser.removeListener(_onPermsChanged);
    NotificationService.enabledForCurrentUser.addListener(_onPermsChanged);

    if (!NotificationService.enabledForCurrentUser.value) {
      debugPrint('[ScheduledAlerts] désactivé (user non owner/admin) — '
          'reste en veille, redémarrera au changement de rôle');
      return;
    }

    _wireAppDatabaseListener();
    _startTicker();
    // Évaluation immédiate au démarrage pour ne pas attendre 30 s.
    evaluateAlerts();
  }

  /// Arrête le service (Timer + listener AppDatabase + listener perms).
  /// Appelé au logout, dispose ou changement de rôle vers non-owner.
  void stop() {
    debugPrint('[ScheduledAlerts] stop()');
    _ticker?.cancel();
    _ticker = null;
    _retryStart?.cancel();
    _retryStart = null;
    if (_wiredAppDb && _onChanged != null) {
      AppDatabase.removeListener(_onChanged!);
      _wiredAppDb = false;
    }
    NotificationService.enabledForCurrentUser.removeListener(_onPermsChanged);
    _started = false;
    _lastEmitted.clear();
    _lastRepeatPlayed.clear();
    _maxPlayedOnce.clear();
  }

  /// Permet à un test ou à un debug screen de forcer une évaluation à un
  /// instant t donné (sans attendre le ticker).
  void evaluateAlerts({DateTime? now}) {
    try {
      // Master toggle : si l'utilisateur a désactivé les alertes via la
      // page paramètres notifications, on émet une liste vide et on sort.
      // Le service reste démarré (les autres niveaux dépendent du statut
      // commande, pas du toggle), mais ne produit ni alertes ni sons.
      if (_isMasterDisabled()) {
        if (!_alertsCtl.isClosed) _alertsCtl.add(const []);
        return;
      }

      final n = now ?? DateTime.now();
      final out = <AlertInfo>[];

      // Optim : on n'examine que les commandes encore "actives" et dans une
      // fenêtre temporelle large autour de maintenant. Coupe ~99% des entrées.
      const windowAheadMs = 24 * 60 * 60 * 1000; // J-1 à 7h ⇒ jusqu'à 31h
      const windowBackMs  =  6 * 60 * 60 * 1000; // overdue silencieux après 6h

      final box = HiveBoxes.ordersBox;
      for (final raw in box.values) {
        try {
          final m = Map<String, dynamic>.from(raw);
          final status = m['status'] as String?;
          final orderId = m['id'] as String?;
          if (orderId == null) continue;

          // Auto-purge des acquittements si la commande n'est plus 'scheduled'.
          if (status != 'scheduled') {
            _purgeAcknowledgedForOrder(orderId);
            _lastEmitted.remove(orderId);
            _lastRepeatPlayed.remove(orderId);
            _maxPlayedOnce.remove(orderId);
            continue;
          }

          final scheduledAtRaw = m['scheduled_at'];
          if (scheduledAtRaw == null) continue;
          final scheduledAt = scheduledAtRaw is String
              ? DateTime.tryParse(scheduledAtRaw)?.toLocal()
              : (scheduledAtRaw is DateTime ? scheduledAtRaw.toLocal() : null);
          if (scheduledAt == null) continue;

          // Fenêtre : dans les 31h à venir, ou dépassée < 6h.
          final deltaMs = scheduledAt.difference(n).inMilliseconds;
          final aheadOk = deltaMs > 0 && deltaMs < windowAheadMs + 7 * 3600 * 1000;
          final backOk  = deltaMs <= 0 && deltaMs.abs() < windowBackMs;
          if (!aheadOk && !backOk) continue;

          final level = _currentLevelFor(scheduledAt, n);
          if (level == null) continue;

          // Niveau effectif = le plus haut atteint dont l'acquittement
          // n'est PAS posé. Si tous les niveaux jusqu'au courant sont
          // acquittés (rare), on n'émet rien — l'opérateur a tout vu.
          final effective = _highestUnacknowledged(orderId, level);
          if (effective == null) {
            _lastEmitted.remove(orderId);
            _lastRepeatPlayed.remove(orderId);
            _maxPlayedOnce.remove(orderId);
            continue;
          }

          final triggeredAt = _triggerInstantFor(scheduledAt, effective);
          final ack = isAcknowledged(orderId, effective);
          out.add(AlertInfo(
            orderId:      orderId,
            shopId:       m['shop_id'] as String?,
            level:        effective,
            scheduledAt:  scheduledAt,
            triggeredAt:  triggeredAt,
            customerName: m['client_name'] as String?,
            acknowledged: ack,
          ));

          _maybePlaySound(orderId, effective, n);

          // Logging : 1 ligne par transition de niveau pour cette commande.
          final last = _lastEmitted[orderId];
          if (last != effective) {
            final mins = (deltaMs / 60000).round();
            final sign = mins >= 0 ? '' : '';
            debugPrint('[ScheduledAlerts] $orderId → level=${effective.name} '
                '(Δ=$sign${mins}min)');
            _lastEmitted[orderId] = effective;
          }
        } catch (e) {
          debugPrint('[ScheduledAlerts] entry error: $e');
        }
      }

      if (!_alertsCtl.isClosed) _alertsCtl.add(out);
    } catch (e, st) {
      // Ne JAMAIS crasher le ticker — on log et on continue.
      debugPrint('[ScheduledAlerts] evaluateAlerts FATAL: $e\n$st');
    }
  }

  // ══════════════════════════════════════════════════════════════════════
  //  ACQUITTEMENTS
  // ══════════════════════════════════════════════════════════════════════

  /// Persiste l'acquittement d'un (orderId, level) dans Hive.
  /// Re-évalue immédiatement pour que l'UI voie le changement sans attendre.
  Future<void> acknowledge(String orderId, AlertLevel level) async {
    try {
      await HiveBoxes.acknowledgedAlertsBox.put(_ackKey(orderId, level), true);
      debugPrint('[ScheduledAlerts] ack $orderId / ${level.name}');
      evaluateAlerts();
    } catch (e) {
      debugPrint('[ScheduledAlerts] acknowledge error: $e');
    }
  }

  /// Lecture synchrone (Hive simple put/get).
  bool isAcknowledged(String orderId, AlertLevel level) {
    try {
      return HiveBoxes.acknowledgedAlertsBox.get(_ackKey(orderId, level))
              as bool? ??
          false;
    } catch (_) {
      return false;
    }
  }

  String _ackKey(String orderId, AlertLevel level) =>
      'ack:$orderId:${level.name}';

  Future<void> _purgeAcknowledgedForOrder(String orderId) async {
    try {
      final box = HiveBoxes.acknowledgedAlertsBox;
      final prefix = 'ack:$orderId:';
      final toDel = box.keys
          .where((k) => k is String && k.startsWith(prefix))
          .toList();
      if (toDel.isEmpty) return;
      await box.deleteAll(toDel);
      debugPrint('[ScheduledAlerts] purge ack $orderId '
          '(${toDel.length} entrées)');
    } catch (e) {
      debugPrint('[ScheduledAlerts] purge error: $e');
    }
  }

  // ══════════════════════════════════════════════════════════════════════
  //  CALCUL DES SEUILS
  // ══════════════════════════════════════════════════════════════════════

  /// Retourne le niveau maximal théoriquement déclenché à `now` selon le
  /// delta `scheduledAt - now`, **filtré par les seuils activés**. Pure
  /// function modulo settings — testable seul (mock settings_box).
  ///
  /// Règles temporelles :
  ///   * Δ < 0                       → overdue   atteint
  ///   * 0   < Δ ≤ 15 min            → max       atteint
  ///   * 15  < Δ ≤ 30 min            → criticalRepeat atteint
  ///   * 30  < Δ ≤ 60 min            → critical  atteint
  ///   * 1h  < Δ ≤ 2h                → warning   atteint
  ///   * Δ > 2h, et `now ≥ J-1@07h00` → info     atteint
  ///
  /// Tous les niveaux atteints SIMULTANÉMENT sont collectés (à H-15min,
  /// max + criticalRepeat + critical + warning + info sont tous techniquement
  /// "atteints"). On filtre ensuite ceux désactivés via les toggles
  /// `alert_threshold_*` et on retourne le PLUS HAUT (gravité max) restant.
  ///
  /// Comportement skip-disabled : si l'opérateur désactive H-1 mais garde
  /// H-30min, à Δ=45min il n'y a aucune alerte ; à Δ=25min on émet
  /// criticalRepeat directement (pas de fallback warning).
  AlertLevel? _currentLevelFor(DateTime scheduledAt, DateTime now) {
    final delta = scheduledAt.difference(now);
    final reached = <AlertLevel>[];
    if (delta.isNegative) {
      reached.add(AlertLevel.overdue);
    } else {
      final mins = delta.inMinutes;
      if (mins <= 15) reached.add(AlertLevel.max);
      if (mins <= 30) reached.add(AlertLevel.criticalRepeat);
      if (mins <= 60) reached.add(AlertLevel.critical);
      if (mins <= 120) reached.add(AlertLevel.warning);
      final triggerInfoAt = _infoTriggerAt(scheduledAt);
      if (!now.isBefore(triggerInfoAt)) reached.add(AlertLevel.info);
    }
    // Filtre les seuils désactivés. Si l'utilisateur a coupé un niveau,
    // on ne retombe PAS sur le niveau temporel précédent — c'est un choix
    // explicite de ne plus être dérangé jusqu'au prochain seuil activé.
    final enabled = reached.where(_isLevelEnabled).toList();
    if (enabled.isEmpty) return null;
    // Plus haut = plus grand index de l'enum (gravité croissante).
    enabled.sort((a, b) => b.index.compareTo(a.index));
    return enabled.first;
  }

  /// Niveau effectif émis = le plus haut atteint **et activé** dont
  /// l'acquittement n'est PAS posé. Permet à l'opérateur d'acquitter les
  /// niveaux individuellement sans masquer les escalades futures.
  AlertLevel? _highestUnacknowledged(String orderId, AlertLevel reached) {
    for (int i = reached.index; i >= 0; i--) {
      final lvl = AlertLevel.values[i];
      if (!_isLevelEnabled(lvl)) continue; // skip désactivé via settings
      if (!isAcknowledged(orderId, lvl)) return lvl;
    }
    return null;
  }

  // ── Lecture settings utilisateur (page paramètres notifications) ─────
  // Toutes les valeurs par défaut = true → zéro régression sur les
  // installations existantes. TODO: granularité per-shop dans futur sprint
  // si demande utilisateur (actuellement device-wide via settings_box).

  bool _isMasterDisabled() {
    try {
      return HiveBoxes.settingsBox
              .get('alert_enabled', defaultValue: true) ==
          false;
    } catch (_) {
      return false;
    }
  }

  bool _isLevelEnabled(AlertLevel level) {
    try {
      return HiveBoxes.settingsBox
              .get('alert_threshold_${level.name}', defaultValue: true) !=
          false;
    } catch (_) {
      return true;
    }
  }

  bool _isSoundEnabled() {
    try {
      return HiveBoxes.settingsBox
              .get('alert_sound_enabled', defaultValue: true) !=
          false;
    } catch (_) {
      return true;
    }
  }

  /// Instant où `level` s'est déclenché pour `scheduledAt` — utilisé par
  /// l'UI pour afficher "il y a 5 min" plutôt que la date brute.
  DateTime _triggerInstantFor(DateTime scheduledAt, AlertLevel level) {
    switch (level) {
      case AlertLevel.info:
        return _infoTriggerAt(scheduledAt);
      case AlertLevel.warning:
        return scheduledAt.subtract(const Duration(hours: 2));
      case AlertLevel.critical:
        return scheduledAt.subtract(const Duration(hours: 1));
      case AlertLevel.criticalRepeat:
        return scheduledAt.subtract(const Duration(minutes: 30));
      case AlertLevel.max:
        return scheduledAt.subtract(const Duration(minutes: 15));
      case AlertLevel.overdue:
        return scheduledAt;
    }
  }

  /// J-1 à 07h00 dans la timezone locale. Pour une commande du
  /// 2026-05-12 14h00, cela retourne 2026-05-11 07h00.
  ///
  /// TODO(timezone): remplacer DateTime.local par shop.timezone une fois
  /// le champ persisté côté boutique (cf. roadmap multishop).
  DateTime _infoTriggerAt(DateTime scheduledAt) {
    final dayBefore = scheduledAt.subtract(const Duration(days: 1));
    return DateTime(dayBefore.year, dayBefore.month, dayBefore.day, 7, 0);
  }

  // ══════════════════════════════════════════════════════════════════════
  //  SONS
  // ══════════════════════════════════════════════════════════════════════

  void _maybePlaySound(String orderId, AlertLevel effective, DateTime now) {
    // Si déjà acquitté à ce niveau, pas de son. (Le filtre est aussi appliqué
    // côté caller via _highestUnacknowledged, mais double check pas cher.)
    if (isAcknowledged(orderId, effective)) return;
    // Toggle utilisateur — page paramètres notifications. Le visuel
    // (banner / modal) reste émis sur le Stream, seul le son est coupé.
    if (!_isSoundEnabled()) return;

    switch (effective) {
      case AlertLevel.info:
      case AlertLevel.warning:
      case AlertLevel.critical:
      case AlertLevel.overdue:
        // 1 fois à la transition. Si on est déjà sur ce niveau au tick
        // suivant, pas de re-jeu.
        if (_lastEmitted[orderId] == effective) return;
        AlarmSoundPlayer.instance.playAlarm(effective);

      case AlertLevel.criticalRepeat:
        // Re-jouer toutes les 5 min jusqu'à ack (ou passage à `max`).
        final last = _lastRepeatPlayed[orderId];
        if (last == null || now.difference(last).inMinutes >= 5) {
          AlarmSoundPlayer.instance.playAlarm(effective);
          _lastRepeatPlayed[orderId] = now;
        }

      case AlertLevel.max:
        // Permanent : on joue à chaque tick (30 s) tant que pas ack.
        // Le _maxPlayedOnce sert juste à forcer un 1er play immédiat lors
        // de l'entrée dans ce niveau, indépendamment du tick.
        AlarmSoundPlayer.instance.playAlarm(effective);
        _maxPlayedOnce.add(orderId);
    }
  }

  // ══════════════════════════════════════════════════════════════════════
  //  HELPERS BOOT
  // ══════════════════════════════════════════════════════════════════════

  bool _isReady() {
    try {
      // Suffit qu'on puisse appeler ordersBox + ackBox sans throw
      // "Box not found". Si pas init, l'accesseur lance — on capture.
      HiveBoxes.ordersBox;
      HiveBoxes.acknowledgedAlertsBox;
      return true;
    } catch (_) {
      return false;
    }
  }

  void _wireAppDatabaseListener() {
    if (_wiredAppDb) return;
    _onChanged = (String table, String shopId) {
      // Re-évaluer dès qu'une commande change (creation, statut, etc.).
      // Le coût est faible (loop sur ordersBox + filtre tôt).
      if (table == 'orders') evaluateAlerts();
    };
    AppDatabase.addListener(_onChanged!);
    _wiredAppDb = true;
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) => evaluateAlerts());
  }

  void _onPermsChanged() {
    if (NotificationService.enabledForCurrentUser.value) {
      // Bascule autorisation : on (re)câble.
      if (!_wiredAppDb) {
        _wireAppDatabaseListener();
        _startTicker();
        evaluateAlerts();
        debugPrint('[ScheduledAlerts] perms ON → service actif');
      }
    } else {
      // Bascule interdiction : on désarme proprement (mais on reste démarré
      // pour réagir à une nouvelle bascule sans avoir à rappeler start()).
      _ticker?.cancel();
      _ticker = null;
      if (_wiredAppDb && _onChanged != null) {
        AppDatabase.removeListener(_onChanged!);
        _wiredAppDb = false;
      }
      _lastEmitted.clear();
      _lastRepeatPlayed.clear();
      _maxPlayedOnce.clear();
      if (!_alertsCtl.isClosed) _alertsCtl.add(const []);
      debugPrint('[ScheduledAlerts] perms OFF → service en veille');
    }
  }
}
