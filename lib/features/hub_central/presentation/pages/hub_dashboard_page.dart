import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/entities/global_stats.dart';
import '../bloc/hub_bloc.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../features/dashboard/data/dashboard_providers.dart';
import '../../../../features/subscription/presentation/widgets/subscription_guard.dart';
import '../../../../shared/providers/auth_provider.dart';
import '../../../../shared/widgets/period_selector.dart';
import '../../../../core/widgets/fortress_logo.dart';

// ═════════════════════════════════════════════════════════════════════════════
// HUB CENTRAL — vue consolidée multi-boutiques.
//
// Architecture :
//   - HubBloc (LoadHubStats / HubLoaded) : alimenté par HubRepositoryImpl
//     qui agrège HiveBoxes.ordersBox par shop_id sur la période courante.
//   - dashPeriodProvider (Riverpod) : pilote la période courante. Partagé
//     avec PeriodSelector et le dashboard mono-boutique.
//
// Couleurs : tout via Theme.of(context).colorScheme + theme.semantic
// (AppSemanticColors). Aucun Color(0xFF…) ni Colors.xxx en dur dans la page.
// ═════════════════════════════════════════════════════════════════════════════

class HubDashboardPage extends ConsumerStatefulWidget {
  const HubDashboardPage({super.key});
  @override
  ConsumerState<HubDashboardPage> createState() => _HubDashboardPageState();
}

class _HubDashboardPageState extends ConsumerState<HubDashboardPage> {
  @override
  void initState() {
    super.initState();
    // Premier chargement : utiliser la période actuellement sélectionnée.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final p = ref.read(dashPeriodProvider);
      context.read<HubBloc>().add(LoadHubStats(_periodKey(p)));
    });
  }

  static String _periodKey(DashPeriod p) => switch (p) {
    DashPeriod.today     => 'today',
    DashPeriod.yesterday => 'today',  // pas de calc dédié, fallback today
    DashPeriod.week      => 'week',
    DashPeriod.month     => 'month',
    DashPeriod.quarter   => 'quarter',
    DashPeriod.year      => 'year',
    DashPeriod.custom    => 'month',  // fallback custom → month
  };

  void _openNewShop() =>
      context.push('${RouteNames.shopSelector}/create');

  @override
  Widget build(BuildContext context) {
    // Recharger les stats à chaque changement de période.
    ref.listen<DashPeriod>(dashPeriodProvider, (prev, next) {
      if (!mounted) return;
      context.read<HubBloc>().add(LoadHubStats(_periodKey(next)));
    });

    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final sem   = theme.semantic;
    final l     = context.l10n;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: BlocBuilder<HubBloc, HubState>(
          builder: (context, state) {
            return RefreshIndicator(
              color: cs.primary,
              onRefresh: () async {
                final p = ref.read(dashPeriodProvider);
                context.read<HubBloc>().add(LoadHubStats(_periodKey(p)));
                await Future<void>.delayed(const Duration(milliseconds: 300));
              },
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                children: [
                  _Topbar(),
                  const SizedBox(height: 18),
                  _ControlsRow(onNewShop: _openNewShop),
                  const SizedBox(height: 18),
                  if (state is HubLoading)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 80),
                      child: Center(child: CircularProgressIndicator(
                          color: cs.primary)),
                    )
                  else if (state is HubError)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 80),
                      child: Center(child: Text(state.message,
                          style: TextStyle(color: sem.danger,
                              fontSize: 13, fontWeight: FontWeight.w600))),
                    )
                  else if (state is HubLoaded)
                    ..._loadedSections(context, state.stats, l)
                  else
                    const SizedBox.shrink(),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  List<Widget> _loadedSections(BuildContext context, GlobalStats s,
      AppLocalizations l) {
    if (s.shopStats.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 60),
          child: Center(child: Text(l.hubNoData,
              style: TextStyle(fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant))),
        ),
      ];
    }
    final palette = _shopPalette(context, s.shopStats.length);
    return [
      _KpiSection(stats: s),
      const SizedBox(height: 18),
      _RevenueByShopChart(stats: s, palette: palette),
      const SizedBox(height: 18),
      if (s.shopStats.length > 1) ...[
        _RevenueShareDonut(stats: s, palette: palette),
        const SizedBox(height: 18),
      ],
      _ShopsHeader(),
      const SizedBox(height: 10),
      ...List.generate(s.shopStats.length, (i) {
        final ss = s.shopStats[i];
        final isTop = s.topShop != null && ss.shopId == s.topShop!.shopId;
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _ShopCard(
            shop:         ss,
            totalRevenue: s.totalRevenue,
            color:        palette[i % palette.length],
            isTop:        isTop && s.shopStats.length > 1,
          ),
        );
      }),
    ];
  }

  /// Palette dérivée du thème : 5 couleurs cycliques utilisées par le chart
  /// barres et le donut. Aucune couleur hardcodée.
  static List<Color> _shopPalette(BuildContext context, int count) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final sem   = theme.semantic;
    return <Color>[
      cs.primary,
      sem.success,
      sem.warning,
      sem.info,
      sem.danger,
    ];
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// TOPBAR — Logo Fortress + nom + avatar utilisateur + notifications
// ═════════════════════════════════════════════════════════════════════════════

class _Topbar extends ConsumerWidget {
  /// Comportement de retour : pop la stack si possible, sinon retour au
  /// sélecteur de boutiques (entrée naturelle vers le hub).
  void _back(BuildContext context) {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(RouteNames.shopSelector);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final sem   = theme.semantic;
    final l     = context.l10n;
    final auth  = ref.watch(authStateProvider);
    final user  = auth.user;
    final initials = _computeInitials(user?.name ?? user?.email ?? '?');
    // Notifications : pas de provider dédié — placeholder à 0.
    const notifCount = 0;

    return Row(children: [
      // Bouton retour
      Tooltip(
        message: l.hubBack,
        child: InkWell(
          onTap: () => _back(context),
          borderRadius: BorderRadius.circular(10),
          child: Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: sem.elevatedSurface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: sem.borderSubtle),
            ),
            alignment: Alignment.center,
            child: Icon(Icons.arrow_back_ios_new_rounded,
                size: 16, color: cs.onSurface),
          ),
        ),
      ),
      const SizedBox(width: 10),
      // Logo Fortress + nom hub
      Container(
        width: 36, height: 36,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const FortressLogo.dark(size: 28),
      ),
      const SizedBox(width: 10),
      Text(l.hubBrand,
          style: theme.textTheme.titleMedium?.copyWith(
            fontSize: 16,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
            color: cs.onSurface,
          )),
      const Spacer(),
      // Notifications
      _IconButtonBadge(
        icon: Icons.notifications_outlined,
        tooltip: l.hubNotifications,
        badge: notifCount,
        badgeColor: sem.danger,
        onTap: () {},
      ),
      const SizedBox(width: 8),
      // Avatar
      Container(
        width: 36, height: 36,
        decoration: BoxDecoration(
          color: cs.primary.withOpacity(0.12),
          shape: BoxShape.circle,
          border: Border.all(color: cs.primary.withOpacity(0.25)),
        ),
        alignment: Alignment.center,
        child: Text(initials,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: cs.primary)),
      ),
    ]);
  }

  static String _computeInitials(String name) {
    final clean = name.trim();
    if (clean.isEmpty) return '?';
    final parts = clean.split(RegExp(r'[\s.@_-]+'))
        .where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return clean[0].toUpperCase();
    if (parts.length == 1) {
      return parts.first.substring(0, parts.first.length.clamp(1, 2)).toUpperCase();
    }
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }
}

class _IconButtonBadge extends StatelessWidget {
  final IconData icon;
  final String   tooltip;
  final int      badge;
  final Color    badgeColor;
  final VoidCallback onTap;
  const _IconButtonBadge({
    required this.icon,
    required this.tooltip,
    required this.badge,
    required this.badgeColor,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: 36, height: 36,
          alignment: Alignment.center,
          child: Stack(clipBehavior: Clip.none, children: [
            Icon(icon, size: 22, color: cs.onSurface),
            if (badge > 0)
              Positioned(
                right: -2, top: -2,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: badgeColor,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  constraints: const BoxConstraints(minWidth: 14),
                  alignment: Alignment.center,
                  child: Text(
                      badge > 99 ? '99+' : '$badge',
                      style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                          color: cs.onError)),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// LIGNE CONTRÔLES — Sélecteur période + bouton Nouvelle boutique
// ═════════════════════════════════════════════════════════════════════════════

class _ControlsRow extends ConsumerWidget {
  final VoidCallback onNewShop;
  const _ControlsRow({required this.onNewShop});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final l     = context.l10n;
    final userId = LocalStorageService.getCurrentUser()?.id ?? '';
    final shopCount = userId.isEmpty
        ? 0
        : LocalStorageService.getShopsForUser(userId).length;
    final newShopBtn = Material(
      color: cs.primary,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onNewShop,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: 12, vertical: 9),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.add_rounded, size: 16, color: cs.onPrimary),
            const SizedBox(width: 6),
            Text(l.hubNewShop,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: cs.onPrimary)),
          ]),
        ),
      ),
    );
    return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      Expanded(child: _CompactPeriodSelector()),
      const SizedBox(width: 10),
      // Guard quota multi-shop — si l'utilisateur a atteint son maxShops,
      // le bouton ouvre UpgradeSheet au lieu de naviguer vers la création.
      SubscriptionGuard.shopQuota(
        currentShopCount: shopCount,
        child: newShopBtn,
      ),
    ]);
  }
}

/// PeriodSelector restreint au sous-ensemble [today, month, quarter, year]
/// pour le hub central. Pilote `dashPeriodProvider` (partagé Riverpod).
class _CompactPeriodSelector extends ConsumerWidget {
  static const _allowed = [
    DashPeriod.today,
    DashPeriod.month,
    DashPeriod.quarter,
    DashPeriod.year,
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme   = Theme.of(context);
    final cs      = theme.colorScheme;
    final sem     = theme.semantic;
    final l       = context.l10n;
    final current = ref.watch(dashPeriodProvider);
    // Si l'état actuel n'est pas dans _allowed (ex: yesterday, week, custom),
    // on l'affiche quand même comme "non-actif" et on traite le tap comme
    // un setter normal.
    String labelOf(DashPeriod p) => switch (p) {
      DashPeriod.today   => l.periodToday,
      DashPeriod.month   => l.periodMonth,
      DashPeriod.quarter => l.periodQuarter,
      DashPeriod.year    => l.periodYear,
      _                  => p.name,
    };
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: _allowed.map((p) {
        final active = current == p;
        return Padding(
          padding: const EdgeInsets.only(right: 6),
          child: GestureDetector(
            onTap: () {
              ref.read(dashPeriodProvider.notifier).state = p;
              ref.read(dashCustomRangeProvider.notifier).state = null;
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: active ? cs.primary : cs.surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: active
                    ? cs.primary
                    : sem.borderSubtle),
              ),
              child: Text(labelOf(p),
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: active
                          ? cs.onPrimary
                          : cs.onSurface.withOpacity(0.7))),
            ),
          ),
        );
      }).toList()),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// 4 KPI CARDS
// ═════════════════════════════════════════════════════════════════════════════

class _KpiSection extends StatelessWidget {
  final GlobalStats stats;
  const _KpiSection({required this.stats});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final sem   = theme.semantic;
    final l     = context.l10n;

    final items = [
      _KpiData(
        label:    l.financesCA,
        value:    '${_compact(stats.totalRevenue)} XAF',
        icon:     Icons.trending_up_rounded,
        color:    sem.success,
        delta:    stats.revenueTrend,
        sub:      _trendLabel(stats.revenueTrend, l),
      ),
      _KpiData(
        label:    l.financesTransactions,
        value:    '${stats.totalTransactions}',
        icon:     Icons.receipt_long_rounded,
        color:    cs.primary,
        delta:    stats.transactionsTrend,
        sub:      _trendLabel(stats.transactionsTrend, l),
      ),
      _KpiData(
        label:    l.hubAvgBasket,
        value:    '${_compact(stats.averageBasket)} XAF',
        icon:     Icons.shopping_basket_rounded,
        color:    sem.warning,
        delta:    stats.averageBasketTrend,
        sub:      _trendLabel(stats.averageBasketTrend, l),
      ),
      _KpiData(
        label:    l.hubUniqueClients,
        value:    '${stats.totalClients}',
        icon:     Icons.people_alt_rounded,
        color:    sem.info,
        delta:    stats.clientsTrend,
        sub:      _trendLabel(stats.clientsTrend, l),
      ),
    ];
    return LayoutBuilder(builder: (ctx, cons) {
      final colW = (cons.maxWidth - 10) / 2;
      return Wrap(spacing: 10, runSpacing: 10,
          children: items.map((k) =>
              SizedBox(width: colW, child: _KpiCard(data: k))).toList());
    });
  }

  static String _compact(double v) {
    if (v.abs() >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
    if (v.abs() >= 1000)    return '${(v / 1000).toStringAsFixed(1)}k';
    return v.toStringAsFixed(0);
  }

  static String _trendLabel(double d, AppLocalizations l) {
    if (d == 0) return '—';
    final sign = d > 0 ? '+' : '−';
    return '$sign${d.abs().toStringAsFixed(1)}%';
  }
}

class _KpiData {
  final String label, value, sub;
  final IconData icon;
  final Color color;
  final double delta;
  const _KpiData({
    required this.label, required this.value, required this.sub,
    required this.icon, required this.color, required this.delta,
  });
}

class _KpiCard extends StatelessWidget {
  final _KpiData data;
  const _KpiCard({required this.data});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final sem   = theme.semantic;
    final positive = data.delta >= 0;
    final trendColor = data.delta == 0
        ? cs.onSurface.withOpacity(0.5)
        : (positive ? sem.success : sem.danger);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: sem.elevatedSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: sem.borderSubtle),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 30, height: 30,
              decoration: BoxDecoration(
                  color: data.color.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(8)),
              child: Icon(data.icon, size: 16, color: data.color)),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: trendColor.withOpacity(0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(
                  data.delta == 0
                      ? Icons.remove_rounded
                      : (positive
                          ? Icons.arrow_upward_rounded
                          : Icons.arrow_downward_rounded),
                  size: 10, color: trendColor),
              const SizedBox(width: 2),
              Text(data.sub,
                  style: TextStyle(fontSize: 9,
                      fontWeight: FontWeight.w800, color: trendColor)),
            ]),
          ),
        ]),
        const SizedBox(height: 10),
        Text(data.value,
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: data.color)),
        const SizedBox(height: 2),
        Text(data.label,
            style: TextStyle(fontSize: 11,
                color: cs.onSurface.withOpacity(0.6),
                fontWeight: FontWeight.w500)),
      ]),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// GRAPHIQUE BARRES — CA par boutique sur les buckets de la période
// ═════════════════════════════════════════════════════════════════════════════

class _RevenueByShopChart extends StatelessWidget {
  final GlobalStats stats;
  final List<Color> palette;
  const _RevenueByShopChart({required this.stats, required this.palette});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final sem   = theme.semantic;
    final l     = context.l10n;

    final labels = stats.bucketLabels;
    final bucketCount = labels.isEmpty
        ? (stats.shopStats.first.salesSeries.length)
        : labels.length;
    if (bucketCount == 0) return const SizedBox.shrink();

    // Calcul max
    double maxVal = 0;
    for (final s in stats.shopStats) {
      for (final v in s.salesSeries) { if (v > maxVal) maxVal = v; }
    }
    if (maxVal == 0) maxVal = 1;
    final chartMax = maxVal * 1.15;
    final rodWidth = bucketCount > 12 ? 3.0 : (bucketCount > 6 ? 5.0 : 7.0);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: sem.elevatedSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: sem.borderSubtle),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(l.hubRevenueByShop,
            style: TextStyle(fontSize: 13,
                fontWeight: FontWeight.w700, color: cs.onSurface)),
        const SizedBox(height: 10),
        Wrap(spacing: 12, runSpacing: 6,
            children: stats.shopStats.asMap().entries.map((e) {
          final i = e.key; final sh = e.value;
          return Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 10, height: 10,
                decoration: BoxDecoration(
                    color: palette[i % palette.length],
                    borderRadius: BorderRadius.circular(3))),
            const SizedBox(width: 6),
            Text(sh.shopName,
                style: TextStyle(fontSize: 11,
                    color: cs.onSurface.withOpacity(0.7),
                    fontWeight: FontWeight.w600)),
          ]);
        }).toList()),
        const SizedBox(height: 12),
        SizedBox(height: 180, child: BarChart(BarChartData(
          maxY: chartMax,
          alignment: BarChartAlignment.spaceAround,
          gridData: FlGridData(
            show: true, drawVerticalLine: false,
            horizontalInterval: chartMax / 4,
            getDrawingHorizontalLine: (_) => FlLine(
                color: sem.trackMuted, strokeWidth: 1),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false)),
            leftTitles: AxisTitles(sideTitles: SideTitles(
              showTitles: true, reservedSize: 38,
              interval: chartMax / 4,
              getTitlesWidget: (v, _) => Text(_compact(v),
                  style: TextStyle(fontSize: 9,
                      color: cs.onSurface.withOpacity(0.5))),
            )),
            bottomTitles: AxisTitles(sideTitles: SideTitles(
              showTitles: true, reservedSize: 22,
              interval: (bucketCount / 6).ceilToDouble()
                  .clamp(1, bucketCount.toDouble()),
              getTitlesWidget: (v, _) {
                final i = v.toInt();
                if (i < 0 || i >= labels.length) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(labels[i],
                      style: TextStyle(fontSize: 9,
                          color: cs.onSurface.withOpacity(0.5))),
                );
              },
            )),
          ),
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipColor: (_) => cs.onSurface,
              tooltipRoundedRadius: 8,
              tooltipPadding: const EdgeInsets.symmetric(
                  horizontal: 8, vertical: 6),
              getTooltipItem: (group, gi, rod, ri) {
                final shop = stats.shopStats[ri];
                return BarTooltipItem(
                  '${shop.shopName} : ${_compact(rod.toY)} XAF',
                  TextStyle(color: rod.color ?? cs.surface,
                      fontSize: 10, fontWeight: FontWeight.w700),
                );
              },
            ),
          ),
          barGroups: [
            for (int i = 0; i < bucketCount; i++)
              BarChartGroupData(
                x: i, barsSpace: 1.5,
                barRods: [
                  for (int s = 0; s < stats.shopStats.length; s++)
                    BarChartRodData(
                      toY: s < stats.shopStats.length
                          ? (i < stats.shopStats[s].salesSeries.length
                              ? stats.shopStats[s].salesSeries[i] : 0)
                          : 0,
                      color: palette[s % palette.length],
                      width: rodWidth,
                      borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(2)),
                    ),
                ],
              ),
          ],
        ))),
      ]),
    );
  }

  static String _compact(double v) {
    if (v.abs() >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
    if (v.abs() >= 1000)    return '${(v / 1000).toStringAsFixed(1)}k';
    return v.toStringAsFixed(0);
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// DONUT — répartition CA par boutique
// ═════════════════════════════════════════════════════════════════════════════

class _RevenueShareDonut extends StatelessWidget {
  final GlobalStats stats;
  final List<Color> palette;
  const _RevenueShareDonut({required this.stats, required this.palette});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final sem   = theme.semantic;
    final l     = context.l10n;
    final total = stats.totalRevenue;

    if (total <= 0) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: sem.elevatedSurface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: sem.borderSubtle),
        ),
        child: Text(l.hubNoData,
            style: TextStyle(fontSize: 12,
                color: cs.onSurface.withOpacity(0.6))),
      );
    }

    final sections = <PieChartSectionData>[];
    for (int i = 0; i < stats.shopStats.length; i++) {
      final ss = stats.shopStats[i];
      if (ss.totalSales <= 0) continue;
      final pct = (ss.totalSales / total) * 100;
      sections.add(PieChartSectionData(
        value:    ss.totalSales,
        color:    palette[i % palette.length],
        radius:   38,
        showTitle: pct >= 6, // n'afficher le %  que si la part est lisible
        title:    '${pct.toStringAsFixed(0)}%',
        titleStyle: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w800,
            color: cs.surface),
      ));
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: sem.elevatedSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: sem.borderSubtle),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(l.hubRevenueShare,
            style: TextStyle(fontSize: 13,
                fontWeight: FontWeight.w700, color: cs.onSurface)),
        const SizedBox(height: 12),
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          SizedBox(
            width: 130, height: 130,
            child: PieChart(PieChartData(
              sections:           sections,
              centerSpaceRadius:  34,
              sectionsSpace:      2,
              borderData:         FlBorderData(show: false),
              startDegreeOffset:  -90,
            )),
          ),
          const SizedBox(width: 14),
          Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: stats.shopStats.asMap().entries.map((e) {
            final i = e.key; final ss = e.value;
            final pct = total > 0 ? (ss.totalSales / total) * 100 : 0;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                Container(width: 8, height: 8,
                    decoration: BoxDecoration(
                        color: palette[i % palette.length],
                        borderRadius: BorderRadius.circular(2))),
                const SizedBox(width: 6),
                Expanded(child: Text(ss.shopName,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface))),
                Text('${pct.toStringAsFixed(1)}%',
                    style: TextStyle(fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: cs.onSurface.withOpacity(0.7))),
              ]),
            );
          }).toList())),
        ]),
      ]),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// SECTION BOUTIQUES
// ═════════════════════════════════════════════════════════════════════════════

class _ShopsHeader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final l     = context.l10n;
    return Text(l.hubMyShops,
        style: TextStyle(fontSize: 14,
            fontWeight: FontWeight.w700, color: cs.onSurface));
  }
}

class _ShopCard extends StatelessWidget {
  final ShopStats shop;
  final double    totalRevenue;
  final Color     color;
  final bool      isTop;
  const _ShopCard({
    required this.shop,
    required this.totalRevenue,
    required this.color,
    required this.isTop,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final sem   = theme.semantic;
    final l     = context.l10n;
    final sharePct = totalRevenue > 0
        ? (shop.totalSales / totalRevenue * 100) : 0.0;
    final progress = (sharePct / 100).clamp(0.0, 1.0);
    final positive = shop.growthRate >= 0;
    final isDown = shop.growthRate < 0;
    final trendColor = positive ? sem.success : sem.danger;
    // Un liseré coloré gauche selon le statut : succès si meilleure, danger
    // si en baisse, sinon pas de liseré.
    final Color? leftStripe = isTop
        ? sem.success
        : (isDown ? sem.danger : null);

    return Container(
      decoration: BoxDecoration(
        color: sem.elevatedSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: sem.borderSubtle),
      ),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (leftStripe != null)
          Container(width: 4, color: leftStripe),
        Expanded(child: InkWell(
          onTap: () => context.go(
              RouteNames.dashboard.replaceAll(':shopId', shop.shopId)),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                // Avatar sombre
                Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                    color: cs.onSurface.withOpacity(0.85),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.storefront_rounded,
                      size: 20, color: cs.surface),
                ),
                const SizedBox(width: 10),
                Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Row(children: [
                    Expanded(child: Text(shop.shopName,
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: cs.onSurface))),
                    if (isTop)
                      _StatusBadge(text: l.hubBadgeBest, color: sem.success),
                    if (isDown) ...[
                      if (isTop) const SizedBox(width: 4),
                      _StatusBadge(text: l.hubBadgeDown, color: sem.danger),
                    ],
                  ]),
                  const SizedBox(height: 2),
                  Text(l.hubTransactionsCount(shop.transactionCount),
                      style: TextStyle(fontSize: 11,
                          color: cs.onSurface.withOpacity(0.6))),
                ])),
                const SizedBox(width: 6),
                Column(crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min, children: [
                  Text(CurrencyFormatter.format(shop.totalSales),
                      style: TextStyle(fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: cs.primary)),
                  const SizedBox(height: 2),
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(positive
                            ? Icons.arrow_upward_rounded
                            : Icons.arrow_downward_rounded,
                        size: 11, color: trendColor),
                    const SizedBox(width: 2),
                    Text('${shop.growthRate.abs().toStringAsFixed(1)}%',
                        style: TextStyle(fontSize: 11,
                            fontWeight: FontWeight.w700, color: trendColor)),
                  ]),
                ]),
                const SizedBox(width: 6),
                Icon(Icons.chevron_right_rounded,
                    size: 18, color: cs.onSurface.withOpacity(0.4)),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 6,
                    backgroundColor: color.withOpacity(0.15),
                    valueColor: AlwaysStoppedAnimation(color),
                  ),
                )),
                const SizedBox(width: 8),
                Text('${sharePct.toStringAsFixed(1)}%',
                    style: TextStyle(fontSize: 11,
                        fontWeight: FontWeight.w700, color: color)),
              ]),
              const SizedBox(height: 3),
              Text(l.hubShareOfRevenue,
                  style: TextStyle(fontSize: 9,
                      color: cs.onSurface.withOpacity(0.5),
                      fontWeight: FontWeight.w500)),
            ]),
          ),
        )),
      ])),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final String text;
  final Color color;
  const _StatusBadge({required this.text, required this.color});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: color.withOpacity(0.12),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(text,
        style: TextStyle(fontSize: 9,
            fontWeight: FontWeight.w800, color: color)),
  );
}
