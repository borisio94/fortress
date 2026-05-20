import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/hive_boxes.dart';
import '../../../features/caisse/domain/entities/sale.dart';
import '../../providers/scheduled_alerts_provider.dart';
import '_order_hydration.dart';
import 'scheduled_order_banner.dart';
import 'scheduled_order_modal.dart';

/// Hôte Riverpod du [ScheduledOrderBanner].
///
/// Inséré une seule fois dans la pile de banners de `adaptive_scaffold`
/// (mobile + desktop pointent sur le même widget — Flutter ne le mount
/// qu'une fois par instance grâce à la déduplication implicite du
/// builder, mais on évite quand même une seconde insertion explicite
/// en wrappant les bandeaux dans une liste partagée).
///
/// Comportement :
///   * Watch `scheduledAlertsProvider` + le toggle `alert_banner_enabled`.
///   * Filtre WARNING+ (les INFO ne s'affichent jamais dans le banner).
///   * Hydrate les `Sale` depuis `ordersBox` pour passer à `ordersById`.
///   * Bouton "Voir" → ouvre `showScheduledOrderModal` (raccourci utile :
///     l'overlay ouvre déjà la modal automatiquement à CRITICAL+, mais
///     pour WARNING l'utilisateur doit cliquer "Voir" lui-même).
class ScheduledAlertsBannerHost extends ConsumerWidget {
  const ScheduledAlertsBannerHost({super.key});

  bool _bannerAllowed() {
    try {
      return HiveBoxes.settingsBox
              .get('alert_banner_enabled', defaultValue: true) !=
          false;
    } catch (_) {
      return true;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!_bannerAllowed()) return const SizedBox.shrink();

    final hasWarn = ref.watch(scheduledAlertsHasWarningProvider);
    if (!hasWarn) return const SizedBox.shrink();

    final alerts = ref.watch(scheduledAlertsProvider).valueOrNull ??
        const [];
    // Filtre WARNING+ (le banner ne reflète pas le niveau INFO).
    final visible = alerts
        .where((a) => a.level.index >= 1) // 1 = warning
        .toList();
    if (visible.isEmpty) return const SizedBox.shrink();

    final ordersById = <String, Sale>{};
    final box = HiveBoxes.ordersBox;
    for (final a in visible) {
      final raw = box.get(a.orderId);
      if (raw == null) continue;
      final s = hydrateOrderForAlert(Map<String, dynamic>.from(raw));
      if (s != null) ordersById[a.orderId] = s;
    }

    return ScheduledOrderBanner(
      alerts:        visible,
      ordersById:    ordersById,
      onViewPressed: () {
        // Ouvrir directement la modal pour la liste filtrée. Si l'overlay
        // l'a déjà ouverte (CRITICAL+), `showDialog` empilerait — mais
        // c'est un cas non-bloquant car l'utilisateur a explicitement tapé.
        final orders = visible
            .map((a) => ordersById[a.orderId])
            .whereType<Sale>()
            .toList();
        if (orders.isEmpty) return;
        showScheduledOrderModal(
          context,
          orders:          orders,
          triggeringLevel: visible
              .map((a) => a.level)
              .reduce((a, b) => a.index >= b.index ? a : b),
        );
      },
    );
  }
}
