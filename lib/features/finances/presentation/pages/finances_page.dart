import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/permisions/subscription_provider.dart';
import '../../../../shared/widgets/kpi_card.dart';
import '../../../../shared/widgets/period_selector.dart';
import '../../../../shared/widgets/view_filter_chip_bar.dart';
import '../../../dashboard/data/dashboard_providers.dart';
import '../../../expenses/presentation/pages/expenses_page.dart';
import '../../../subscription/domain/models/plan_type.dart';
import '../../../subscription/presentation/widgets/subscription_guard.dart';
import '../widgets/expenses_breakdown_widget.dart';
import '../widgets/losses_journal_widget.dart';
import '../widgets/payment_breakdown_widget.dart';

// ═════════════════════════════════════════════════════════════════════════════
// FINANCES — vue comptable.
// La navigation entre sous-vues (Chiffre d'affaires · Dépenses · Pertes ·
// Bénéfice net) se fait via les sous-items du drawer Finances ; la page
// n'affiche QUE le contenu du sous-menu sélectionné (`?tab=`). Consomme
// `dashDataProvider` déjà existant — aucun nouveau state dédié.
// ═════════════════════════════════════════════════════════════════════════════

enum _FinancesTab { revenus, depenses, pertes, bilan }

/// Résout le query param `tab` (cf. sous-items du drawer Finances) vers
/// l'index d'onglet initial. Valeurs : revenus|depenses|pertes|bilan.
int _tabIndexFromParam(String? p) => switch (p) {
  'depenses' => 1,
  'pertes'   => 2,
  'bilan'    => 3,
  _          => 0, // revenus (défaut)
};

class FinancesPage extends ConsumerStatefulWidget {
  final String shopId;
  /// Onglet ouvert au montage (piloté par les sous-items du drawer).
  final String? initialTab;
  const FinancesPage({super.key, required this.shopId, this.initialTab});
  @override
  ConsumerState<FinancesPage> createState() => _FinancesPageState();
}

class _FinancesPageState extends ConsumerState<FinancesPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(
      length: _FinancesTab.values.length,
      initialIndex: _tabIndexFromParam(widget.initialTab),
      vsync: this,
    );
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

  @override
  Widget build(BuildContext context) {
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
      current: _FinancesTab.values[_tab.index],
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
              size: 64, color: cs.primary.withValues(alpha:0.6)),
          const SizedBox(height: 16),
          Text(context.l10n.upgradeFeatureTitle,
              textAlign: TextAlign.center,
              style: AppTextStyles.subtitleBold.copyWith(
                  color: cs.onSurface)),
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
  final _FinancesTab current;
  const _FinancesBody({required this.shopId, required this.current});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(dashDataProvider(shopId));

    return Column(children: [
      // Zone filtres compacte (période + emplacement collés, sans gros
      // espacements). Chacun scrolle horizontalement indépendamment.
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        child: const PeriodSelector(),
      ),
      const SizedBox(height: 2),
      // Filtre emplacement global : pilote dashViewFilterProvider →
      // KPI, graphiques (dashDataProvider) ET l'onglet Dépenses suivent.
      ViewFilterChipBar(shopId: shopId, useTabs: true),
      const SizedBox(height: 6),
      // Plus de rangée de cartes-onglets : la navigation entre sous-vues
      // se fait désormais via les sous-items du drawer Finances
      // (Chiffre d'affaires / Dépenses / Pertes / Bénéfice net). La page
      // n'affiche QUE le contenu du sous-menu sélectionné. Liseré couleur
      // = repère visuel discret de la vue active.
      Container(height: 3, color: _colorForTab(current)),
      Expanded(child: switch (current) {
        _FinancesTab.revenus  => _RevenusTab(data: data),
        _FinancesTab.depenses => ExpensesView(shopId: shopId),
        _FinancesTab.pertes   => _PertesTab(shopId: shopId, data: data),
        _FinancesTab.bilan    => _BilanTab(data: data),
      }),
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

  static String _fmt(double v) => CurrencyFormatter.compact(v);

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
          unit:  CurrencyFormatter.currentSymbol,
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

  static String _fmt(double v) => CurrencyFormatter.compact(v);

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
            unit:  CurrencyFormatter.currentSymbol,
            icon:  Icons.trending_down_rounded,
            color: AppColors.error,
            errorIndicator: data.totalLoss > 0,
          ),
          KpiData(
            label: l.financesBilanScrapped,
            value: _fmt(data.scrappedLoss),
            unit:  CurrencyFormatter.currentSymbol,
            icon:  Icons.delete_forever_rounded,
            color: AppColors.error,
            errorIndicator: data.scrappedLoss > 0,
          ),
          KpiData(
            label: l.financesBilanRepair,
            value: _fmt(data.repairCost),
            unit:  CurrencyFormatter.currentSymbol,
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

  static String _fmt(double v) => CurrencyFormatter.compact(v);

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
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).semantic.borderSubtle),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha:0.03),
            blurRadius: 4, offset: const Offset(0, 2))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 28, height: 28,
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha:0.10),
                borderRadius: BorderRadius.circular(7),
              ),
              child: Icon(Icons.account_balance_rounded,
                  size: 15, color: AppColors.primary)),
          const SizedBox(width: 8),
          Text(l.financesTabBilan,
              style: AppTextStyles.bodyBold),
        ]),
        const SizedBox(height: 12),
        _row(l.financesBilanCA,
            '+${_fmt(data.totalSales)} ${CurrencyFormatter.currentSymbol}',
            AppColors.textPrimary),
        const SizedBox(height: 4),
        _row(l.financesBilanProductCost,
            '−${_fmt(productCost)} ${CurrencyFormatter.currentSymbol}',
            AppColors.textSecondary),
        if (data.scrappedLoss > 0) ...[
          const SizedBox(height: 4),
          _row(l.financesBilanScrapped,
              '−${_fmt(data.scrappedLoss)} ${CurrencyFormatter.currentSymbol}',
              AppColors.error),
        ],
        if (data.repairCost > 0) ...[
          const SizedBox(height: 4),
          _row(l.financesBilanRepair,
              '−${_fmt(data.repairCost)} ${CurrencyFormatter.currentSymbol}',
              AppColors.warning),
        ],
        if (data.operatingExpenses > 0) ...[
          const SizedBox(height: 4),
          _row(l.financesBilanExpenses,
              '−${_fmt(data.operatingExpenses)} ${CurrencyFormatter.currentSymbol}',
              AppColors.error),
        ],
        const SizedBox(height: 8),
        Divider(height: 1, color: Theme.of(context).semantic.borderSubtle),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: Text(l.financesBilanNet,
              style: AppTextStyles.bodySmBold)),
          Text(
              '${isPositive ? '+' : '−'}${_fmt(net.abs())} ${CurrencyFormatter.currentSymbol}',
              style: AppTextStyles.label.copyWith(
                  color: isPositive
                      ? AppColors.primary
                      : AppColors.error)),
        ]),
      ]),
    );
  }

  Widget _row(String label, String value, Color color) => Row(children: [
    Expanded(child: Text(label, style: AppTextStyles.bodySmSecondary)),
    Text(value, style: AppTextStyles.bodySmBold.copyWith(color: color)),
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
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Theme.of(context).semantic.borderSubtle),
    ),
    child: Column(children: [
      Icon(Icons.bar_chart_rounded,
          size: 40, color: AppColors.textHint),
      const SizedBox(height: 8),
      Text(message,
          textAlign: TextAlign.center,
          style: AppTextStyles.bodySmSecondary),
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

  static String _compact(double v) => CurrencyFormatter.compact(v);

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
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Theme.of(context).semantic.borderSubtle),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha:0.03),
            blurRadius: 5, offset: const Offset(0, 2))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(l.dashSalesOverview,
            style: AppTextStyles.label),
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
                        style: AppTextStyles.captionHint),
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
                          style: AppTextStyles.micro),
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
                              style: AppTextStyles.micro),
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
      Text(label, style: AppTextStyles.captionBold),
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
              color: cs.onSurface.withValues(alpha:0.6),
              height: 1.5,
            ),
          ),
        ]),
      ),
    );
  }
}
