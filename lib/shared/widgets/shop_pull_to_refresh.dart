import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/app_database.dart';
import '../../core/theme/app_colors.dart';
import '../../features/dashboard/data/dashboard_providers.dart';
import 'app_snack.dart';

/// Actualise la boutique à la demande de l'utilisateur, puis signale le
/// résultat.
///
/// `AppDatabase.refreshShopData` vide la file hors ligne avant de tirer, et chaque
/// table tirée notifie ses écouteurs. Le signal dashboard force en plus le
/// recalcul des providers qui en dépendent (KPI, finances…).
Future<void> refreshShopFromUi(
    BuildContext context, WidgetRef ref, String shopId) async {
  final online = await AppDatabase.refreshShopData(shopId);
  if (!context.mounted) return;
  ref.read(dashSignalProvider.notifier).state++;
  if (!online) {
    AppSnack.info(context, 'Hors ligne — données locales affichées');
  }
}

/// Geste « tirer vers le bas pour actualiser », posé une seule fois par le
/// cadre commun des pages de boutique (`AdaptiveScaffold`).
///
/// Il réagit à la zone défilante VERTICALE de la page, quelle que soit sa
/// profondeur dans l'arbre. Une page qui a déjà sa propre actualisation la
/// garde : quand l'indicateur le plus proche de la zone défilée n'est pas
/// celui du cadre, le geste global s'efface — sans quoi deux indicateurs
/// tourneraient ensemble.
///
/// Limite : une zone qui ne peut pas défiler (contenu plus court que l'écran)
/// n'émet aucun geste. Les pages concernées forcent leur défilement
/// (`AlwaysScrollableScrollPhysics`).
class ShopPullToRefresh extends ConsumerStatefulWidget {
  final String shopId;
  final Widget child;
  const ShopPullToRefresh({
    super.key,
    required this.shopId,
    required this.child,
  });

  @override
  ConsumerState<ShopPullToRefresh> createState() => _ShopPullToRefreshState();
}

class _ShopPullToRefreshState extends ConsumerState<ShopPullToRefresh> {
  final _indicatorKey = GlobalKey<RefreshIndicatorState>();

  bool _accepts(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return false;
    final nearest = notification.context
        ?.findAncestorStateOfType<RefreshIndicatorState>();
    return nearest == null || identical(nearest, _indicatorKey.currentState);
  }

  @override
  Widget build(BuildContext context) => RefreshIndicator(
        key: _indicatorKey,
        color: AppColors.primary,
        notificationPredicate: _accepts,
        onRefresh: () => refreshShopFromUi(context, ref, widget.shopId),
        child: widget.child,
      );
}

/// Bouton « Actualiser » de la barre du haut sur grand écran, où le geste de
/// tirer n'existe pas à la souris. Même action que le geste.
class ShopRefreshButton extends ConsumerStatefulWidget {
  final String shopId;
  const ShopRefreshButton({super.key, required this.shopId});

  @override
  ConsumerState<ShopRefreshButton> createState() => _ShopRefreshButtonState();
}

class _ShopRefreshButtonState extends ConsumerState<ShopRefreshButton> {
  bool _busy = false;

  Future<void> _refresh() async {
    setState(() => _busy = true);
    try {
      await refreshShopFromUi(context, ref, widget.shopId);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: 'Actualiser',
        onPressed: _busy ? null : _refresh,
        icon: _busy
            ? const SizedBox(
                width: 18, height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.refresh_rounded, size: 20),
      );
}
