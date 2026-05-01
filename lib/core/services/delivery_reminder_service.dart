import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;
import '../../features/caisse/domain/entities/sale.dart';

/// Service centralisé pour les rappels de livraison (notifications locales
/// programmées à la date `scheduledAt` d'une commande).
///
/// - Android : notification programmée via AlarmManager.
/// - iOS / macOS : notification locale.
/// - Linux : notification locale.
/// - **Windows / Web : non supporté → no-op silencieux**
///   (`flutter_local_notifications` n'expose pas `zonedSchedule` sur ces
///   plateformes — appeler le service crasherait sinon).
///
/// L'id de notification est dérivé de l'id de commande (hashCode & 0x7fffffff),
/// ce qui permet d'annuler / remplacer de manière déterministe.
class DeliveryReminderService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  /// True si la plateforme supporte les notifications programmées.
  /// Windows et Web ne sont pas supportés par le package — on bypass
  /// pour éviter des UnimplementedError / LateInitializationError.
  static bool get _supported {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS
        || Platform.isMacOS  || Platform.isLinux;
  }

  /// Canal Android (requis Android 8+).
  static const _androidChannel = AndroidNotificationChannel(
    'delivery_reminders',
    'Rappels de livraison',
    description: 'Alerte quand la date de livraison d\'une commande arrive.',
    importance: Importance.high,
  );

  /// Initialise le plugin. Idempotent. À appeler une fois au démarrage
  /// de l'app (depuis main.dart après HiveBoxes.init()).
  static Future<void> init() async {
    if (_initialized) return;
    if (!_supported) {
      _initialized = true; // marque comme initialisé pour bypasser les calls
      debugPrint('[DeliveryReminderService] ⊘ plateforme non supportée — no-op');
      return;
    }
    try {
      tz_data.initializeTimeZones();
      // Sur les plateformes sans timezone auto, on se rabat sur UTC.
      // Pas critique : les notifs sont à quelques minutes près.
      try {
        tz.setLocalLocation(tz.getLocation('Africa/Douala'));
      } catch (_) {
        // Fallback silencieux
      }

      const initAndroid = AndroidInitializationSettings('@mipmap/ic_launcher');
      const initIOS = DarwinInitializationSettings(
        requestAlertPermission:  true,
        requestBadgePermission:  true,
        requestSoundPermission:  true,
      );
      const initMacOS = DarwinInitializationSettings();
      const initLinux = LinuxInitializationSettings(
          defaultActionName: 'Ouvrir');

      await _plugin.initialize(
        const InitializationSettings(
          android: initAndroid,
          iOS:     initIOS,
          macOS:   initMacOS,
          linux:   initLinux,
        ),
      );

      // Créer le canal Android (idempotent)
      final androidImpl = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await androidImpl?.createNotificationChannel(_androidChannel);
      await androidImpl?.requestNotificationsPermission();

      _initialized = true;
      debugPrint('[DeliveryReminderService] ✅ initialisé');
    } catch (e) {
      debugPrint('[DeliveryReminderService] ❌ init: $e');
    }
  }

  /// Calcule un id de notification 32-bit à partir de l'id texte d'une commande.
  static int _notifId(String orderId) => orderId.hashCode & 0x7fffffff;

  /// Programme un rappel pour une commande. Si la date est dans le passé
  /// ou nulle, n'envoie pas. Si un rappel existe déjà pour cette commande,
  /// il est remplacé.
  ///
  /// Retourne `true` si programmé, `false` sinon (pas de date, date passée,
  /// plateforme non supportée, etc.).
  static Future<bool> scheduleFor(Sale order) async {
    if (!_supported) return false; // Windows/Web → no-op
    if (!_initialized) await init();
    final when = order.scheduledAt;
    if (when == null) return false;
    if (order.id == null) return false;
    // Ignorer si déjà passée (on envoie pas une notif dans le passé)
    if (when.isBefore(DateTime.now())) return false;
    // Ignorer si la commande n'a plus besoin de rappel
    if (order.status == SaleStatus.completed ||
        order.status == SaleStatus.cancelled ||
        order.status == SaleStatus.refused ||
        order.status == SaleStatus.refunded) {
      await cancelFor(order.id!);
      return false;
    }

    try {
      final body = order.clientName != null
          ? 'Livraison à effectuer pour ${order.clientName} · '
              '${order.total.toStringAsFixed(0)}'
          : 'Une commande arrive à échéance.';

      await _plugin.zonedSchedule(
        _notifId(order.id!),
        'Livraison aujourd\'hui',
        body,
        tz.TZDateTime.from(when, tz.local),
        NotificationDetails(
          android: AndroidNotificationDetails(
            _androidChannel.id,
            _androidChannel.name,
            channelDescription: _androidChannel.description,
            importance: Importance.high,
            priority:   Priority.high,
          ),
          iOS: const DarwinNotificationDetails(),
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        payload: order.id,
      );
      debugPrint('[DeliveryReminderService] scheduled order=${order.id} at $when');
      return true;
    } catch (e) {
      debugPrint('[DeliveryReminderService] scheduleFor error: $e');
      return false;
    }
  }

  /// Annule le rappel pour une commande (par exemple commande livrée avant
  /// l'échéance, ou annulée).
  static Future<void> cancelFor(String orderId) async {
    if (!_supported) return; // Windows/Web → no-op
    if (!_initialized) return;
    try {
      await _plugin.cancel(_notifId(orderId));
      debugPrint('[DeliveryReminderService] cancelled order=$orderId');
    } catch (e) {
      debugPrint('[DeliveryReminderService] cancelFor error: $e');
    }
  }
}
