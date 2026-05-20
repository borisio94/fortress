import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/i18n/app_localizations.dart';
import '../../../core/services/scheduled_order_alert_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/duration_formatter.dart';
import '../../../features/caisse/domain/entities/sale.dart';

/// Banner top fin (36 px) qui résume les alertes commandes actives.
///
/// Sprint 2A : composant pur, son `alerts` lui est passé par le caller
/// (sprint 2B observera le Stream de [ScheduledOrderAlertService] et
/// reconstruira le banner à chaque snapshot).
///
/// Couleur selon le niveau MAX présent dans `alerts` :
///   * WARNING                            → `theme.semantic.warning`
///   * CRITICAL / CRITICAL_REPEAT / MAX   → `theme.semantic.danger`
///   * OVERDUE                            → gris foncé fixe (couleur de
///     retard universelle, pas variant palette boutique)
///
/// Compteur live (Timer 1s) refresh juste le `Text`. "✕" snooze 5min in-mem
/// (ne touche PAS aux acquittements). "Voir" → callback caller.
class ScheduledOrderBanner extends StatefulWidget {
  final List<AlertInfo> alerts;
  final Map<String, Sale> ordersById;
  final VoidCallback onViewPressed;
  const ScheduledOrderBanner({
    super.key,
    required this.alerts,
    required this.ordersById,
    required this.onViewPressed,
  });

  @override
  State<ScheduledOrderBanner> createState() => _ScheduledOrderBannerState();
}

class _ScheduledOrderBannerState extends State<ScheduledOrderBanner> {
  Timer? _ticker;
  DateTime? _snoozedUntil;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.alerts.isEmpty) return const SizedBox.shrink();
    if (_snoozedUntil != null && DateTime.now().isBefore(_snoozedUntil!)) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final sem   = theme.semantic;
    final l     = context.l10n;

    // Niveau le plus haut (= max gravité) parmi les alertes actives.
    final topLevel = widget.alerts
        .map((a) => a.level)
        .reduce((a, b) => a.index >= b.index ? a : b);
    final bg = _backgroundFor(topLevel, sem);

    final isOverdue = topLevel == AlertLevel.overdue;
    final n = widget.alerts.length;
    final label = (n > 1)
        ? l.scheduledAlertMultipleOrders(n)
        : _singleLabel(context, l, widget.alerts.first, isOverdue);

    return Container(
      width: double.infinity,
      height: 36,
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(children: [
        Icon(
            isOverdue
                ? Icons.timer_off_rounded
                : (n > 1
                    ? Icons.warning_amber_rounded
                    : Icons.timer_outlined),
            color: Colors.white, size: 16),
        const SizedBox(width: 8),
        Expanded(child: Text(
          label,
          style: const TextStyle(
              color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
          maxLines: 1, overflow: TextOverflow.ellipsis,
        )),
        TextButton(
          onPressed: widget.onViewPressed,
          style: TextButton.styleFrom(
            foregroundColor: Colors.white,
            minimumSize: const Size(0, 28),
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          child: Text(l.scheduledAlertSeen,
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w800,
                  decoration: TextDecoration.underline)),
        ),
        // Bouton "✕" snooze 5min — masqué si N>1 (l'utilisateur doit traiter
        // chaque alerte individuellement via la modal).
        if (n == 1)
          IconButton(
            icon: const Icon(Icons.close_rounded, color: Colors.white, size: 16),
            tooltip: 'Masquer 5 min',
            onPressed: () => setState(() {
              _snoozedUntil = DateTime.now().add(const Duration(minutes: 5));
            }),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
      ]),
    );
  }

  Color _backgroundFor(AlertLevel lvl, AppSemanticColors sem) {
    switch (lvl) {
      case AlertLevel.warning:
        return sem.warning;
      case AlertLevel.critical:
      case AlertLevel.criticalRepeat:
      case AlertLevel.max:
        return sem.danger;
      case AlertLevel.overdue:
        // Gris foncé fixe — pas variant palette boutique (couleur
        // de retard universelle, comprise dans toutes les palettes).
        return const Color(0xFF1F2937);
      case AlertLevel.info:
        // INFO ne devrait jamais s'afficher dans le banner (cf. spec :
        // niveau INFO = juste cloche topbar). Fallback sécurité.
        return sem.info;
    }
  }

  String _singleLabel(BuildContext ctx, AppLocalizations l, AlertInfo a,
      bool isOverdue) {
    final order = widget.ordersById[a.orderId];
    final name = (order?.clientName ?? '').trim();
    final delta = a.scheduledAt.difference(DateTime.now());
    final time = DurationFormatter.compact(delta);
    final prefix = isOverdue
        ? l.scheduledAlertOverdue
        : l.scheduledAlertBannerTitle;
    final timeLabel = isOverdue
        ? l.scheduledAlertOverdueBy(time)
        : l.scheduledAlertCountdown(time);
    if (name.isEmpty) return '$prefix · $timeLabel';
    return '$prefix — $name · $timeLabel';
  }
}
