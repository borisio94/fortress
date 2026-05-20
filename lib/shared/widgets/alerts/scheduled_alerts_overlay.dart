import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/scheduled_order_alert_service.dart';
import '../../../core/storage/hive_boxes.dart';
import '../../../core/i18n/app_localizations.dart';
import '../../../features/caisse/domain/entities/sale.dart';
import '../../providers/scheduled_alerts_provider.dart';
import '_order_hydration.dart';
import 'favicon_blinker.dart'
    if (dart.library.html) 'favicon_blinker_web.dart';
import 'scheduled_order_modal.dart';

/// Widget invisible (renvoie son `child` tel quel) qui pilote globalement :
///   * L'ouverture/fermeture automatique de [ScheduledOrderModal] dès qu'une
///     alerte de niveau ≥ CRITICAL est active.
///   * Le démarrage/arrêt de [FaviconBlinker] (web uniquement) sur le même
///     critère, avec le nom du client de la commande la plus urgente.
///
/// Monté dans le `builder:` de `MaterialApp.router` (cf. `app.dart`) pour
/// avoir un Navigator/Overlay ancestor disponible — sans ça `showDialog`
/// ne trouverait pas de cible.
///
/// Le modal est poussé via `showDialog` (utilise l'Overlay ambiant). Si
/// l'utilisateur navigate via le router pendant que la modal est affichée,
/// elle est automatiquement détachée par GoRouter (la barrière dialog est
/// au-dessus de la route mais sous le shell — un changement de route
/// détruit la modal). Le tick suivant du provider ré-ouvrira la modal car
/// la liste d'alertes est toujours non-vide → invariant respecté.
class ScheduledAlertsOverlay extends ConsumerStatefulWidget {
  final Widget child;
  const ScheduledAlertsOverlay({super.key, required this.child});

  @override
  ConsumerState<ScheduledAlertsOverlay> createState() =>
      _ScheduledAlertsOverlayState();
}

class _ScheduledAlertsOverlayState
    extends ConsumerState<ScheduledAlertsOverlay> {
  bool _modalOpen = false;
  bool _faviconActive = false;

  @override
  void dispose() {
    if (_faviconActive) {
      FaviconBlinker.stop();
      _faviconActive = false;
    }
    super.dispose();
  }

  /// Lecture des toggles utilisateur (page paramètres notifications).
  /// Tout activé par défaut (zéro régression).
  bool _modalAllowed() {
    try {
      return HiveBoxes.settingsBox
              .get('alert_modal_enabled', defaultValue: true) !=
          false;
    } catch (_) {
      return true;
    }
  }

  bool _faviconAllowed() {
    if (!kIsWeb) return false;
    try {
      return HiveBoxes.settingsBox
              .get('alert_favicon_enabled', defaultValue: true) !=
          false;
    } catch (_) {
      return true;
    }
  }

  bool _titleFlashAllowed() {
    if (!kIsWeb) return false;
    try {
      return HiveBoxes.settingsBox
              .get('alert_title_flash_enabled', defaultValue: true) !=
          false;
    } catch (_) {
      return true;
    }
  }

  /// Récupère le `Sale` complet depuis Hive (le service ne stocke que
  /// l'`AlertInfo` minimal). Utilisé pour passer la commande complète à
  /// la modal (client / phone / items / total). Cf. `_order_hydration.dart`
  /// pour l'extraction des champs e-commerce ignorés par SaleModel.
  List<Sale> _hydrateAlerts(List<AlertInfo> alerts) {
    final box = HiveBoxes.ordersBox;
    final out = <Sale>[];
    for (final a in alerts) {
      final raw = box.get(a.orderId);
      if (raw == null) continue;
      final map = Map<String, dynamic>.from(raw);
      final s = hydrateOrderForAlert(map);
      if (s != null) out.add(s);
    }
    return out;
  }

  AlertLevel _topLevel(List<AlertInfo> alerts) =>
      alerts.map((a) => a.level).reduce((a, b) => a.index >= b.index ? a : b);

  @override
  Widget build(BuildContext context) {
    final alertsAsync = ref.watch(scheduledAlertsProvider);
    final alerts = alertsAsync.valueOrNull ?? const <AlertInfo>[];

    // Filtre : on n'ouvre la modal que pour les niveaux CRITICAL+.
    // WARNING reste visible dans le banner uniquement.
    final critical = alerts
        .where((a) => a.level.index >= AlertLevel.critical.index)
        .toList();

    // ── Pilotage modal ────────────────────────────────────────────────
    if (critical.isNotEmpty && !_modalOpen && _modalAllowed()) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _modalOpen) return;
        _showModal(context, critical);
      });
    } else if (critical.isEmpty && _modalOpen) {
      // Toutes les alertes critiques ont été acquittées ou les commandes
      // ont changé de statut. Ferme la modal si encore ouverte.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _modalOpen) {
          // ignore: use_build_context_synchronously
          Navigator.of(context, rootNavigator: true).maybePop();
          _modalOpen = false;
        }
      });
    }

    // ── Pilotage FaviconBlinker (web only) ───────────────────────────
    if (critical.isNotEmpty && _faviconAllowed() && !_faviconActive) {
      final l = AppLocalizations.of(context);
      final prefix = _titleFlashAllowed()
          ? (l?.scheduledAlertTitleFlash ?? '⚠ COMMANDE — ')
          : '';
      final suffix = critical.first.customerName ?? '';
      FaviconBlinker.start(flashPrefix: prefix, suffix: suffix);
      _faviconActive = true;
    } else if (critical.isEmpty && _faviconActive) {
      FaviconBlinker.stop();
      _faviconActive = false;
    } else if (critical.isNotEmpty && _faviconActive && _titleFlashAllowed()) {
      // Refresh paramètres si une nouvelle alerte arrive avec autre client.
      final l = AppLocalizations.of(context);
      final prefix = l?.scheduledAlertTitleFlash ?? '⚠ COMMANDE — ';
      final suffix = critical.first.customerName ?? '';
      FaviconBlinker.start(flashPrefix: prefix, suffix: suffix);
    }

    return widget.child;
  }

  Future<void> _showModal(BuildContext context, List<AlertInfo> alerts) async {
    _modalOpen = true;
    final orders = _hydrateAlerts(alerts);
    if (orders.isEmpty) {
      _modalOpen = false;
      return;
    }
    try {
      await showScheduledOrderModal(
        context,
        orders:          orders,
        triggeringLevel: _topLevel(alerts),
      );
    } catch (e) {
      debugPrint('[ScheduledAlertsOverlay] showModal error: $e');
    } finally {
      _modalOpen = false;
    }
  }
}
