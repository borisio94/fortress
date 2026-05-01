import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/storage/hive_boxes.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/permisions/subscription_provider.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/kpi_card.dart';
import '../../../../shared/widgets/period_selector.dart';
import '../../../dashboard/data/dashboard_providers.dart';
import '../../../expenses/presentation/pages/expenses_page.dart';
import '../../../subscription/domain/models/plan_type.dart';
import '../../../subscription/presentation/widgets/subscription_guard.dart';
import '../widgets/expenses_breakdown_widget.dart';
import '../widgets/losses_journal_widget.dart';
import '../widgets/payment_breakdown_widget.dart';

// ═════════════════════════════════════════════════════════════════════════════
// FINANCES — vue comptable.
// 4 KPI cliquables (CA · Dépenses · Pertes · Bénéfice net) au-dessus de
// 4 onglets correspondants (Revenus · Dépenses · Pertes · Bilan). Un tap
// sur une KPI active l'onglet correspondant.
// Consomme uniquement `dashDataProvider` + `financesPreviousSnapshotProvider`
// déjà existants — aucun nouveau state dédié.
// ═════════════════════════════════════════════════════════════════════════════

enum _FinancesTab { revenus, depenses, pertes, bilan }

class FinancesPage extends ConsumerStatefulWidget {
  final String shopId;
  const FinancesPage({super.key, required this.shopId});
  @override
  ConsumerState<FinancesPage> createState() => _FinancesPageState();
}

class _FinancesPageState extends ConsumerState<FinancesPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: _FinancesTab.values.length, vsync: this);
    _tab.addListener(() {
      if (mounted) setState(() {}); // rebuild pour la KPI active
    });
    AppDatabase.addListener(_onDataChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(dashSignalProvider.notifier).state++;
    });
  }

  @override
  void dispose() {
    AppDatabase.removeListener(_onDataChanged);
    _tab.dispose();
    super.dispose();
  }

  void _onDataChanged(String table, String shopId) {
    if (!mounted) return;
    if (shopId != widget.shopId && shopId != '_all') return;
    ref.read(dashSignalProvider.notifier).state++;
  }

  void _selectTab(_FinancesTab t) => _tab.animateTo(t.index);

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final plan  = ref.watch(currentPlanProvider);
    final perms = ref.watch(permissionsProvider(widget.shopId));

    // Garde rôle : page finances réservée admin/owner (employé non
    // concerné par les KPI globaux et le détail des dépenses).
    if (!perms.canViewFinances) {
      return const _AccessDeniedPlaceholder();
    }

    // Garde feature : la page finances complète est verrouillée derrière
    // Feature.finances. Si non incluse → placeholder + UpgradeSheet sur tap.
    if (!plan.hasFeature(Feature.finances)) {
      return _LockedFeaturePlaceholder(feature: Feature.finances);
    }
    return _FinancesBody(
      shopId: widget.shopId,
      tab: _tab,
      current: _FinancesTab.values[_tab.index],
      onSelect: _selectTab,
    );
  }
}

// ─── Placeholder « feature verrouillée » ─────────────────────────────────────
class _LockedFeaturePlaceholder extends StatelessWidget {
  final Feature feature;
  const _LockedFeaturePlaceholder({required this.feature});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.workspace_premium_rounded,
              size: 64, color: cs.primary.withOpacity(0.6)),
          const SizedBox(height: 16),
          Text(context.l10n.upgradeFeatureTitle,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16,
                  fontWeight: FontWeight.w800, color: cs.onSurface)),
          const SizedBox(height: 18),
          ElevatedButton.icon(
            onPressed: () => UpgradeSheet.showFeature(
                context, feature: feature),
            icon: const Icon(Icons.arrow_forward_rounded, size: 16),
            label: Text(context.l10n.upgradeViewPlans),
            style: ElevatedButton.styleFrom(
              backgroundColor: cs.primary,
              foregroundColor: cs.onPrimary,
              elevation: 0,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(
                  horizontal: 18, vertical: 12),
            ),
          ),
        ]),
      ),
    );
  }
}

class _FinancesBody extends ConsumerWidget {
  final String shopId;
  final TabController tab;
  final _FinancesTab current;
  final ValueChanged<_FinancesTab> onSelect;
  const _FinancesBody({required this.shopId, required this.tab,
      required this.current, required this.onSelect});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data     = ref.watch(dashDataProvider(shopId));
    final previous = ref.watch(financesPreviousSnapshotProvider(shopId));
    final l        = context.l10n;

    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: const PeriodSelector(),
      ),
      const SizedBox(height: 12),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: _FinancesKpiGrid(
          shopId:   shopId,
          data:     data,
          previous: previous,
          current:  current,
          onSelect: onSelect,
        ),
      ),
      const SizedBox(height: 12),
      TabBar(
        controller: tab,
        labelColor:   _colorForTab(current),
        unselectedLabelColor: AppColors.textSecondary,
        indicatorColor: _colorForTab(current),
        indicatorWeight: 2.5,
        labelStyle: const TextStyle(
            fontSize: 12, fontWeight: FontWeight.w700),
        unselectedLabelStyle: const TextStyle(
            fontSize: 12, fontWeight: FontWeight.w600),
        tabs: [
          Tab(text: l.financesTabRevenus),
          Tab(text: l.financesTabDepenses),
          Tab(text: l.financesTabPertes),
          Tab(text: l.financesTabBilan),
        ],
      ),
      Expanded(child: TabBarView(
        controller: tab,
        children: [
          _RevenusTab(data: data),
          ExpensesView(shopId: shopId),
          _PertesTab(shopId: shopId, data: data),
          _BilanTab(data: data),
        ],
      )),
    ]);
  }
}

Color _colorForTab(_FinancesTab t) => switch (t) {
  _FinancesTab.revenus  => AppColors.secondary,
  _FinancesTab.depenses => AppColors.warning,
  _FinancesTab.pertes   => AppColors.error,
  _FinancesTab.bilan    => AppColors.primary,
};

// ═════════════════════════════════════════════════════════════════════════════
// GRID 4 KPI CARDS — chacune cliquable, active l'onglet correspondant.
// Pill tendance vs période précédente alimenté par
// `financesPreviousSnapshotProvider`.
// ═════════════════════════════════════════════════════════════════════════════

class _FinancesKpiGrid extends ConsumerWidget {
  final String shopId;
  final DashData data;
  final FinancialSnapshot previous;
  final _FinancesTab current;
  final ValueChanged<_FinancesTab> onSelect;
  const _FinancesKpiGrid({required this.shopId, required this.data,
      required this.previous, required this.current, required this.onSelect});

  static String _fmt(double v) {
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000)    return '${(v / 1000).toStringAsFixed(1)}k';
    return v.toStringAsFixed(0);
  }

  /// Variation en pourcentage, formatée en pill. Retourne ('', true) si
  /// impossible à calculer (division par zéro).
  static ({String delta, bool positive}) _trend(double now, double prev) {
    if (prev == 0) {
      if (now == 0) return (delta: '', positive: true);
      return (delta: '', positive: now >= 0);
    }
    final pct = ((now - prev) / prev.abs()) * 100;
    final sign = pct >= 0 ? '+' : '';
    return (delta: '$sign${pct.toStringAsFixed(1)}%', positive: pct >= 0);
  }

  int _countExpenseEntries() {
    var count = 0;
    for (final raw in HiveBoxes.expensesBox.values) {
      try {
        final m = Map<String, dynamic>.from(raw as Map);
        if (m['shop_id'] == shopId) count++;
      } catch (_) {}
    }
    return count;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final salesT    = _trend(data.totalSales,        previous.totalSales);
    final expensesT = _trend(data.operatingExpenses, previous.operatingExpenses);
    final lossesCurrent  = data.totalLoss + data.scrappedLoss + data.repairCost;
    final lossesPrevious = previous.totalLoss +
        previous.scrappedLoss + previous.repairCost;
    final lossesT   = _trend(lossesCurrent, lossesPrevious);
    final netT      = _trend(data.netProfit,         previous.netProfit);

    final scrapEntriesCount =
        ref.watch(scrapJournalProvider(shopId)).length;
    final expenseEntries = _countExpenseEntries();

    KpiData card({
      required _FinancesTab tab,
      required String label,
      required double value,
      required IconData icon,
      required Color color,
      required ({String delta, bool positive}) trend,
      required String subtext,
      bool errorIndicator = false,
    }) => KpiData(
      label: label,
      value: _fmt(value),
      unit: 'XAF',
      icon: icon,
      color: color,
      delta: trend.delta,
      // Dépenses et pertes : "+X%" signifie ça a **augmenté** → mauvais signe
      positive: (tab == _FinancesTab.depenses || tab == _FinancesTab.pertes)
          ? !trend.positive
          : trend.positive,
      subtext: subtext,
      active: current == tab,
      errorIndicator: errorIndicator,
      onTap: () => onSelect(tab),
    );

    final kpis = <KpiData>[
      card(
        tab:   _FinancesTab.revenus,
        label: l.financesKpiSales,
        value: data.totalSales,
        icon:  Icons.trending_up_rounded,
        color: AppColors.secondary,
        trend: salesT,
        subtext: l.financesSubTransactions
            .replaceAll('%d', data.orderCount.toString()),
      ),
      card(
        tab:   _FinancesTab.depenses,
        label: l.financesKpiExpenses,
        value: data.operatingExpenses,
        icon:  Icons.account_balance_wallet_outlined,
        color: AppColors.warning,
        trend: expensesT,
        subtext: l.financesSubEntries
            .replaceAll('%d', expenseEntries.toString()),
      ),
      card(
        tab:   _FinancesTab.pertes,
        label: l.financesKpiLosses,
        value: lossesCurrent,
        icon:  Icons.trending_down_rounded,
        color: AppColors.error,
        trend: lossesT,
        subtext: l.financesSubIncidents
            .replaceAll('%d', scrapEntriesCount.toString()),
      ),
      card(
        tab:   _FinancesTab.bilan,
        label: l.financesKpiNet,
        value: data.netProfit,
        icon:  Icons.account_balance_rounded,
        color: data.netProfit >= 0 ? AppColors.primary : AppColors.error,
        trend: netT,
        subtext: l.financesVsPrevious,
      ),
    ];

    return KpiGrid(kpis: kpis, minCardWidth: 150);
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// ONGLET REVENUS — graphique courbes + transactions + panier moyen
// ═════════════════════════════════════════════════════════════════════════════

class _RevenusTab extends StatelessWidget {
  final DashData data;
  const _RevenusTab({required this.data});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _RevenueSubKpis(data: data),
        const SizedBox(height: 14),
        if (data.totalSales == 0 && data.salesSeries
                .every((v) => v == 0))
          _EmptyCard(message: l.financesEmptyNoData)
        else
          _SalesBarChart(
            sales:    data.salesSeries,
            profit:   data.profitSeries,
            expenses: data.expensesSeries,
            labels:   data.labels,
          ),
        const SizedBox(height: 16),
        PaymentBreakdownWidget(recentTx: data.recentTx),
      ],
    );
  }
}

class _RevenueSubKpis extends StatelessWidget {
  final DashData data;
  const _RevenueSubKpis({required this.data});

  static String _fmt(double v) {
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000)    return '${(v / 1000).toStringAsFixed(1)}k';
    return v.toStringAsFixed(0);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return KpiGrid(
      kpis: [
        KpiData(
          label: l.financesTransactions,
          value: data.orderCount.toString(),
          icon:  Icons.receipt_long_rounded,
          color: AppColors.info,
        ),
        KpiData(
          label: l.financesPanier,
          value: _fmt(data.avgTicket),
          unit:  'XAF',
          icon:  Icons.shopping_basket_rounded,
          color: AppColors.primary,
        ),
      ],
      minCardWidth: 140,
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// ONGLET PERTES — journal des pertes + rebuts / réparations
// ═════════════════════════════════════════════════════════════════════════════

class _PertesTab extends ConsumerWidget {
  final String shopId;
  final DashData data;
  const _PertesTab({required this.shopId, required this.data});

  static String _fmt(double v) {
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000)    return '${(v / 1000).toStringAsFixed(1)}k';
    return v.toStringAsFixed(0);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final hasPertes = data.totalLoss > 0 ||
        data.scrappedLoss > 0 ||
        data.repairCost > 0;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        KpiGrid(kpis: [
          KpiData(
            label: l.dashLoss,
            value: _fmt(data.totalLoss),
            unit:  'XAF',
            icon:  Icons.trending_down_rounded,
            color: AppColors.error,
            errorIndicator: data.totalLoss > 0,
          ),
          KpiData(
            label: l.financesBilanScrapped,
            value: _fmt(data.scrappedLoss),
            unit:  'XAF',
            icon:  Icons.delete_forever_rounded,
            color: AppColors.error,
            errorIndicator: data.scrappedLoss > 0,
          ),
          KpiData(
            label: l.financesBilanRepair,
            value: _fmt(data.repairCost),
            unit:  'XAF',
            icon:  Icons.build_rounded,
            color: AppColors.warning,
          ),
        ], minCardWidth: 140),
        const SizedBox(height: 14),
        if (!hasPertes)
          _EmptyCard(message: l.financesEmptyNoData)
        else
          LossesJournalWidget(shopId: shopId),
      ],
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// ONGLET BILAN — récapitulatif comptable + breakdown dépenses
// ═════════════════════════════════════════════════════════════════════════════

class _BilanTab extends StatelessWidget {
  final DashData data;
  const _BilanTab({required this.data});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _FinancialRecap(data: data),
        const SizedBox(height: 16),
        if (data.expensesByCategory.isNotEmpty)
          ExpensesBreakdownWidget(byCategory: data.expensesByCategory),
      ],
    );
  }
}

class _FinancialRecap extends StatelessWidget {
  final DashData data;
  const _FinancialRecap({required this.data});

  static String _fmt(double v) {
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000)    return '${(v / 1000).toStringAsFixed(1)}k';
    return v.toStringAsFixed(0);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final productCost = (data.totalSales - data.totalProfit)
        .clamp(0.0, double.infinity);
    final net        = data.netProfit;
    final isPositive = net >= 0;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03),
            blurRadius: 4, offset: const Offset(0, 2))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 28, height: 28,
              decoration: BoxDecoration(
                color: AppColors.primary.withOpacity(0.10),
                borderRadius: BorderRadius.circular(7),
              ),
              child: Icon(Icons.account_balance_rounded,
                  size: 15, color: AppColors.primary)),
          const SizedBox(width: 8),
          Text(l.financesTabBilan,
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 12),
        _row(l.financesBilanCA, '+${_fmt(data.totalSales)} XAF',
            AppColors.textPrimary),
        const SizedBox(height: 4),
        _row(l.financesBilanProductCost, '−${_fmt(productCost)} XAF',
            AppColors.textSecondary),
        if (data.scrappedLoss > 0) ...[
          const SizedBox(height: 4),
          _row(l.financesBilanScrapped, '−${_fmt(data.scrappedLoss)} XAF',
              AppColors.error),
        ],
        if (data.repairCost > 0) ...[
          const SizedBox(height: 4),
          _row(l.financesBilanRepair, '−${_fmt(data.repairCost)} XAF',
              AppColors.warning),
        ],
        if (data.operatingExpenses > 0) ...[
          const SizedBox(height: 4),
          _row(l.financesBilanExpenses,
              '−${_fmt(data.operatingExpenses)} XAF',
              AppColors.error),
        ],
        const SizedBox(height: 8),
        const Divider(height: 1, color: AppColors.divider),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: Text(l.financesBilanNet,
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700))),
          Text('${isPositive ? '+' : '−'}${_fmt(net.abs())} XAF',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800,
                  color: isPositive
                      ? AppColors.primary
                      : AppColors.error)),
        ]),
      ]),
    );
  }

  Widget _row(String label, String value, Color color) => Row(children: [
    Expanded(child: Text(label, style: const TextStyle(
        fontSize: 12, color: AppColors.textSecondary))),
    Text(value, style: TextStyle(fontSize: 12,
        fontWeight: FontWeight.w700, color: color)),
  ]);
}

// ═════════════════════════════════════════════════════════════════════════════
// WIDGETS UTILITAIRES
// ═════════════════════════════════════════════════════════════════════════════

class _EmptyCard extends StatelessWidget {
  final String message;
  const _EmptyCard({required this.message});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(24),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: AppColors.divider),
    ),
    child: Column(children: [
      Icon(Icons.bar_chart_rounded,
          size: 40, color: AppColors.textHint),
      const SizedBox(height: 8),
      Text(message,
          textAlign: TextAlign.center,
          style: const TextStyle(
              fontSize: 12, color: AppColors.textSecondary)),
    ]),
  );
}

// ─── Graphique barres groupées CA / bénéfice / dépenses ─────────────────────
// Identique à `_SalesBarChart` du dashboard : 3 rods par bucket (CA · profit ·
// dépenses opérationnelles), mêmes couleurs sémantiques, même tooltip.
// Le sélecteur de période inline du dashboard n'est pas répliqué ici car la
// page Finances expose déjà un PeriodSelector global au-dessus.
class _SalesBarChart extends StatelessWidget {
  final List<double> sales;
  final List<double> profit;
  final List<double> expenses;
  final List<String> labels;
  const _SalesBarChart({
    required this.sales,
    required this.profit,
    this.expenses = const [],
    required this.labels,
  });

  static String _compact(double v) {
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000)    return '${(v / 1000).toStringAsFixed(1)}k';
    return v.toStringAsFixed(0);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final salesColor    = AppColors.primary;
    final profitColor   = AppColors.secondary;
    final expensesColor = AppColors.error;

    final allValues = [...sales, ...profit, ...expenses];
    final maxVal    = allValues.fold<double>(0, (m, v) => v > m ? v : m);
    final chartMax  = maxVal == 0 ? 1.0 : maxVal * 1.15;

    final hasExpenses = expenses.any((v) => v > 0);
    final bucketCount = sales.length;
    final baseWidth = bucketCount > 20 ? 4.0
        : bucketCount > 10 ? 7.0
        : 10.0;
    final rodWidth = hasExpenses ? baseWidth * 0.85 : baseWidth;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.divider),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03),
            blurRadius: 5, offset: const Offset(0, 2))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(l.dashSalesOverview,
            style: const TextStyle(fontSize: 14,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary)),
        const SizedBox(height: 8),
        Wrap(spacing: 14, runSpacing: 6, children: [
          _LegendDot(color: salesColor,    label: l.dashChartSales),
          _LegendDot(color: profitColor,   label: l.dashChartProfit),
          if (hasExpenses)
            _LegendDot(color: expensesColor, label: l.dashOperatingExpenses),
        ]),
        const SizedBox(height: 12),
        SizedBox(
          height: 200,
          child: maxVal == 0
              ? Center(child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.show_chart_rounded,
                        size: 32, color: AppColors.textHint),
                    const SizedBox(height: 6),
                    Text(l.dashNoSalesYet,
                        style: const TextStyle(
                            fontSize: 11, color: AppColors.textHint)),
                  ]))
              : BarChart(BarChartData(
                  maxY: chartMax,
                  alignment: BarChartAlignment.spaceAround,
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    horizontalInterval: chartMax / 4,
                    getDrawingHorizontalLine: (_) => const FlLine(
                      color: AppColors.inputFill,
                      strokeWidth: 1,
                    ),
                  ),
                  borderData: FlBorderData(show: false),
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    leftTitles: AxisTitles(sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 38,
                      interval: chartMax / 4,
                      getTitlesWidget: (v, _) => Text(_compact(v),
                          style: const TextStyle(
                              fontSize: 9, color: AppColors.textHint)),
                    )),
                    bottomTitles: AxisTitles(sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 22,
                      interval: (labels.length / 6).ceilToDouble()
                          .clamp(1, labels.length.toDouble()),
                      getTitlesWidget: (v, _) {
                        final i = v.toInt();
                        if (i < 0 || i >= labels.length) {
                          return const SizedBox.shrink();
                        }
                        return Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(labels[i],
                              style: const TextStyle(
                                  fontSize: 9,
                                  color: AppColors.textHint)),
                        );
                      },
                    )),
                  ),
                  barTouchData: BarTouchData(
                    touchTooltipData: BarTouchTooltipData(
                      getTooltipColor: (_) => AppColors.textPrimary,
                      tooltipRoundedRadius: 8,
                      tooltipPadding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 6),
                      getTooltipItem: (group, gi, rod, ri) {
                        final name = ri == 0
                            ? l.dashChartSales
                            : ri == 1
                                ? l.dashChartProfit
                                : l.dashOperatingExpenses;
                        return BarTooltipItem(
                          '$name : ${_compact(rod.toY)}',
                          TextStyle(
                              color: rod.color ?? Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w700),
                        );
                      },
                    ),
                  ),
                  barGroups: [
                    for (int i = 0; i < sales.length; i++)
                      BarChartGroupData(
                        x: i,
                        barsSpace: 2,
                        barRods: [
                          BarChartRodData(
                            toY: sales[i],
                            color: salesColor,
                            width: rodWidth,
                            borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(3)),
                          ),
                          BarChartRodData(
                            toY: i < profit.length ? profit[i] : 0,
                            color: profitColor,
                            width: rodWidth,
                            borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(3)),
                          ),
                          if (hasExpenses)
                            BarChartRodData(
                              toY: i < expenses.length ? expenses[i] : 0,
                              color: expensesColor,
                              width: rodWidth,
                              borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(3)),
                            ),
                        ],
                      ),
                  ],
                )),
        ),
      ]),
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendDot({required this.color, required this.label});
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(width: 8, height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      const SizedBox(width: 6),
      Text(label, style: const TextStyle(fontSize: 11,
          fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
    ],
  );
}


class _AccessDeniedPlaceholder extends StatelessWidget {
  const _AccessDeniedPlaceholder();
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 72, height: 72,
            decoration: BoxDecoration(
              color: AppColors.primarySurface,
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.lock_rounded,
                size: 34, color: AppColors.primary),
          ),
          const SizedBox(height: 16),
          Text(
            'Accès réservé',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'La page Finances est réservée au propriétaire et aux '
            'administrateurs de la boutique.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 13,
              color: cs.onSurface.withOpacity(0.6),
              height: 1.5,
            ),
          ),
        ]),
      ),
    );
  }
}
