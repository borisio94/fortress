import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/scheduled_order_alert_service.dart';

/// Stream global des alertes commandes programmées actives.
///
/// Pattern aligné sur `syncStatusProvider` (cf. sync_status_banner.dart) :
/// les widgets consommateurs (banner, overlay modal, halo cloche) sont des
/// `ConsumerWidget` qui font `ref.watch(scheduledAlertsProvider).valueOrNull`.
///
/// Les valeurs émises proviennent de `ScheduledOrderAlertService.instance.alerts`
/// — broadcast stream alimenté par le ticker 30 s + le listener AppDatabase
/// du service (cf. sprint 1).
final scheduledAlertsProvider = StreamProvider<List<AlertInfo>>((ref) {
  return ScheduledOrderAlertService.instance.alerts;
});

/// True si au moins une alerte de niveau ≥ CRITICAL est active.
/// Utilisé par :
///   * `ScheduledAlertsOverlay` pour décider d'ouvrir / fermer la modal.
///   * Le halo rouge animé autour de la cloche topbar.
/// Provider dérivé pour éviter de rebuild les widgets consommateurs à
/// chaque tick si le booléen ne change pas.
final scheduledAlertsHasCriticalProvider = Provider<bool>((ref) {
  final list = ref.watch(scheduledAlertsProvider).valueOrNull ?? const [];
  return list.any((a) => a.level.index >= AlertLevel.critical.index);
});

/// True si au moins une alerte de niveau ≥ WARNING est active.
/// Utilisé par le banner host pour décider de s'afficher.
final scheduledAlertsHasWarningProvider = Provider<bool>((ref) {
  final list = ref.watch(scheduledAlertsProvider).valueOrNull ?? const [];
  return list.any((a) => a.level.index >= AlertLevel.warning.index);
});
