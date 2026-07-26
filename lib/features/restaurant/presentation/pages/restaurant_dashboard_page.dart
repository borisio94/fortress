import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/services/restaurant_reporting_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/period_selector.dart';
import '../../../../shared/widgets/product_image_card.dart';
import '../../../dashboard/data/dashboard_providers.dart';
import '../../data/restaurant_dashboard_providers.dart';
import '../widgets/resto_kpi_tile.dart';

/// Tableau de bord dédié à la restauration.
///
/// Reprend la composition d'une console de restaurant : bandeau de 4 tuiles
/// colorées, répartition en anneau, activité hebdomadaire en barres, et
/// carrousel des plats qui marchent.
///
/// Les COMPOSANTS sont fidèles à la maquette de référence ; le FOND de page
/// et les cartes suivent le thème de l'application (clair/sombre, couleur de
/// marque de la boutique). Seules les 4 teintes de tuiles sont fixes : ce
/// sont des couleurs de données, au même titre qu'une légende de graphique.
///
/// L'écran e-commerce (`DashboardPage`) n'est pas touché : le routeur choisit
/// l'un ou l'autre selon le secteur de la boutique.
class RestaurantDashboardPage extends ConsumerWidget {
  final String shopId;

  const RestaurantDashboardPage({super.key, required this.shopId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(dashDataProvider(shopId));
    final resto = ref.watch(restaurantDashProvider(shopId));
    final finance = ref.watch(restaurantFinanceProvider(shopId));

    return AppScaffold(
      shopId: shopId,
      title: 'Tableau de bord',
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _KpiRow(shopId: shopId, resto: resto),
          const SizedBox(height: 16),
          _FinanceKpiRow(report: finance),
          const SizedBox(height: 16),
          _FinanceChartCard(report: finance),
          const SizedBox(height: 16),
          _SectorCard(report: finance),
          const SizedBox(height: 16),
          _TwoCol(
            first: _ChannelCard(resto: resto),
            second: _WeekChart(resto: resto),
          ),
          const SizedBox(height: 16),
          _TrendingCard(shopId: shopId, top: data.topProducts),
        ],
      ),
    );
  }
}

/// Bandeau des 4 tuiles colorées.
///
/// Indicateurs d'EXPLOITATION uniquement (commandes, cuisine, salle, livraison).
/// Toute la lecture FINANCIÈRE (recette, dépense, ticket) a été retirée du
/// tableau de bord : la gestion des finances gastronomiques passe désormais
/// exclusivement par le module Finances restaurant (fiche recette + hub).
class _KpiRow extends StatelessWidget {
  final String shopId;
  final RestaurantDashData resto;

  const _KpiRow({required this.shopId, required this.resto});

  @override
  Widget build(BuildContext context) {
    final tiles = <Widget>[
      RestoKpiTile(
        value: resto.totalOrders.toString(),
        label: 'Commandes',
        icon: Icons.receipt_long_rounded,
        color: RestoTileColors.orders,
        onTap: () => context.push('/shop/$shopId/caisse/orders'),
      ),
      RestoKpiTile(
        value: resto.inKitchen.toString(),
        label: 'En cuisine',
        icon: Icons.restaurant_rounded,
        color: RestoTileColors.expense,
      ),
      RestoKpiTile(
        value: '${resto.busyTables} / ${resto.totalTables}',
        label: 'Tables occupées',
        icon: Icons.table_chart_outlined,
        color: RestoTileColors.average,
        onTap: () => context.push('/shop/$shopId/restaurant/tables'),
      ),
      RestoKpiTile(
        value: resto.delivery.toString(),
        label: 'Livraisons',
        icon: Icons.local_shipping_rounded,
        color: RestoTileColors.revenue,
      ),
    ];

    return LayoutBuilder(builder: (_, c) {
      final wide = c.maxWidth >= 760;
      return GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: tiles.length,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: wide ? 4 : 2,
          // Tuiles larges et basses, comme la maquette : le badge et le
          // texte sont côte à côte, pas empilés.
          childAspectRatio: wide ? 2.15 : 1.85,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
        ),
        itemBuilder: (_, i) => tiles[i],
      );
    });
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  FINANCES (module finances — Lot 3)
// ═══════════════════════════════════════════════════════════════════════

/// Les quatre courbes du graphique finances — et les quatre KPI du bandeau.
enum _Curve { sales, profit, expense, loss }

extension _CurveX on _Curve {
  String get label => switch (this) {
        _Curve.sales => 'Ventes',
        _Curve.profit => 'Bénéfice',
        _Curve.expense => 'Dépenses',
        _Curve.loss => 'Pertes',
      };

  Color get color => switch (this) {
        _Curve.sales => RestoSeriesColors.sales,
        _Curve.profit => RestoSeriesColors.profit,
        _Curve.expense => RestoSeriesColors.expense,
        _Curve.loss => RestoSeriesColors.loss,
      };
}

/// Bandeau financier : ventes, bénéfice net, dépenses, pertes de la période.
///
/// Les couleurs sont celles des courbes du graphique juste en dessous : une
/// pastille verte ici = la courbe verte là.
class _FinanceKpiRow extends StatelessWidget {
  final RestaurantFinanceReport report;
  const _FinanceKpiRow({required this.report});

  @override
  Widget build(BuildContext context) {
    final tiles = <Widget>[
      _FinanceTile(curve: _Curve.sales, amount: report.revenue),
      _FinanceTile(
        curve: _Curve.profit,
        amount: report.netProfit,
        // La marge brute contextualise le bénéfice : un bénéfice net faible
        // avec une marge brute élevée désigne les charges, pas la carte.
        hint: 'Marge brute ${report.marginRate.toStringAsFixed(0)} %',
      ),
      _FinanceTile(
        curve: _Curve.expense,
        amount: report.expenses,
        hint: 'dont matières '
            '${CurrencyFormatter.format(report.materialCost)}',
      ),
      _FinanceTile(curve: _Curve.loss, amount: report.losses.toDouble()),
    ];

    return LayoutBuilder(builder: (_, c) {
      final wide = c.maxWidth >= 760;
      return GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: tiles.length,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: wide ? 4 : 2,
          childAspectRatio: wide ? 2.15 : 1.85,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
        ),
        itemBuilder: (_, i) => tiles[i],
      );
    });
  }
}

/// Tuile d'indicateur financier : pastille de couleur de courbe + montant.
class _FinanceTile extends StatelessWidget {
  final _Curve curve;
  final double amount;
  final String? hint;

  const _FinanceTile({required this.curve, required this.amount, this.hint});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final sem = theme.semantic;
    // Un bénéfice négatif se lit en rouge : c'est l'information la plus
    // importante de l'écran, elle ne doit pas se fondre dans le violet.
    final negative = curve == _Curve.profit && amount < 0;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: sem.borderSubtle),
      ),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 38,
            decoration: BoxDecoration(
              color: negative ? sem.danger : curve.color,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    CurrencyFormatter.format(amount),
                    maxLines: 1,
                    style: AppTextStyles.title.copyWith(
                      color: negative ? sem.danger : cs.onSurface,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  hint ?? curve.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.bodySm
                      .copyWith(color: cs.onSurface.withValues(alpha: 0.6)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Graphique financier à courbes activables.
///
/// Quatre courbes indépendantes (ventes · bénéfice · dépenses · pertes), une
/// puce par courbe, et un filtre par secteur d'activité.
///
/// **Vue par secteur** : charges fixes et pertes ne sont pas ventilables par
/// secteur (un loyer ne se découpe pas entre le bar et la cuisine). En vue
/// secteur, « Dépenses » ne compte donc que les matières et la courbe
/// « Pertes » est retirée — la légende le dit explicitement plutôt que
/// d'afficher une courbe globale sous une étiquette de secteur.
class _FinanceChartCard extends ConsumerStatefulWidget {
  final RestaurantFinanceReport report;
  const _FinanceChartCard({required this.report});

  @override
  ConsumerState<_FinanceChartCard> createState() => _FinanceChartCardState();
}

class _FinanceChartCardState extends ConsumerState<_FinanceChartCard> {
  final Set<_Curve> _on = {..._Curve.values};

  /// `null` = vue globale · `''` = ventes sans secteur · sinon un activityId.
  String? _sectorKey;

  /// Secteur sélectionné, ou `null` si vue globale — ou si le secteur choisi
  /// n'a plus de vente sur la nouvelle période (retour au global plutôt qu'un
  /// graphique vide sans explication).
  SectorLine? get _sector {
    final key = _sectorKey;
    if (key == null) return null;
    for (final s in widget.report.sectors) {
      if ((s.activityId ?? '') == key) return s;
    }
    return null;
  }

  /// Le filtre par secteur n'a de sens que si au moins une activité réelle a
  /// vendu : sinon la seule ligne serait « Sans secteur », égale au global.
  bool get _sectorsUsable =>
      widget.report.sectors.any((s) => s.activityId != null);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final sem = theme.semantic;
    final report = widget.report;
    final sector = _sector;
    final n = report.labels.length;
    final period = ref.watch(dashPeriodProvider);

    // Séries affichées : globales, ou celles du secteur sélectionné.
    final zero = List<double>.filled(n, 0);
    final sales = sector?.revenueSeries ?? report.revenueSeries;
    final expenses = sector?.costSeries ?? report.expenseSeries;
    final losses = sector == null ? report.lossSeries : zero;
    final profit = [
      for (var i = 0; i < n; i++) sales[i] - expenses[i] - losses[i],
    ];
    final series = {
      _Curve.sales: sales,
      _Curve.profit: profit,
      _Curve.expense: expenses,
      _Curve.loss: losses,
    };

    // En vue secteur, la courbe des pertes n'existe pas : on la retire au
    // lieu de tracer une ligne plate qui laisserait croire à zéro perte.
    final selectable = sector == null
        ? _Curve.values
        : [_Curve.sales, _Curve.profit, _Curve.expense];
    final shown = selectable.where(_on.contains).toList();

    return _Card(
      title: 'Finances',
      subtitle: sector == null
          ? _periodLabel(period)
          : '${sector.name} · ${_periodLabel(period)}',
      trailing: const PeriodSelector(mode: PeriodSelectorMode.inline),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_sectorsUsable) ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _Choice(
                  label: 'Global',
                  selected: _sectorKey == null,
                  onTap: () => setState(() => _sectorKey = null),
                ),
                for (final s in report.sectors)
                  _Choice(
                    label: s.name,
                    selected: _sectorKey == (s.activityId ?? ''),
                    onTap: () =>
                        setState(() => _sectorKey = s.activityId ?? ''),
                  ),
              ],
            ),
            const SizedBox(height: 14),
          ],

          // ── Puces de courbes + tout activer / désactiver ──────────────
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final c in selectable)
                      _CurveChip(
                        curve: c,
                        selected: _on.contains(c),
                        onTap: () => setState(() {
                          if (!_on.remove(c)) _on.add(c);
                        }),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => setState(() {
                  if (_on.length == _Curve.values.length) {
                    _on.clear();
                  } else {
                    _on.addAll(_Curve.values);
                  }
                }),
                child: Text(
                  _on.length == _Curve.values.length
                      ? 'Tout masquer'
                      : 'Tout afficher',
                  style: AppTextStyles.bodySm.copyWith(color: cs.primary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          if (report.isEmpty)
            const _EmptyBlock(
              icon: Icons.show_chart_rounded,
              message: 'Aucun mouvement financier sur cette période.',
            )
          else if (shown.isEmpty)
            const _EmptyBlock(
              icon: Icons.visibility_off_outlined,
              message: 'Toutes les courbes sont masquées.',
            )
          else
            SizedBox(
              height: 230,
              child: LineChart(_chartData(context, shown, series, report)),
            ),

          if (sector != null) ...[
            const SizedBox(height: 10),
            Text(
                'Vue secteur : « Dépenses » ne compte que les matières. '
                'Charges fixes et pertes ne sont pas ventilables par secteur.',
                style: AppTextStyles.micro.copyWith(color: sem.borderSubtle)),
          ],
        ],
      ),
    );
  }

  LineChartData _chartData(
    BuildContext context,
    List<_Curve> shown,
    Map<_Curve, List<double>> series,
    RestaurantFinanceReport report,
  ) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final sem = theme.semantic;
    final n = report.labels.length;

    // Bornes calculées sur les SEULES courbes affichées : masquer les ventes
    // doit re-zoomer sur ce qui reste, sinon les petites courbes s'écrasent.
    // Le zéro est toujours inclus — un bénéfice négatif doit se voir passer
    // sous l'axe.
    var lo = 0.0, hi = 0.0;
    for (final c in shown) {
      for (final v in series[c]!) {
        if (v < lo) lo = v;
        if (v > hi) hi = v;
      }
    }
    if (lo == 0 && hi == 0) hi = 1;
    final pad = (hi - lo) * 0.12;
    final minY = lo - pad;
    final maxY = hi + pad;
    final yStep = ((maxY - minY) / 4).abs();

    // Au plus ~6 étiquettes en bas, sinon elles se chevauchent sur mobile.
    final xStep = (n / 6).ceil();

    return LineChartData(
      minY: minY,
      maxY: maxY,
      minX: 0,
      maxX: (n - 1).toDouble(),
      gridData: FlGridData(
        show: true,
        drawVerticalLine: false,
        horizontalInterval: yStep <= 0 ? null : yStep,
        getDrawingHorizontalLine: (_) =>
            FlLine(color: sem.borderSubtle, strokeWidth: 1),
      ),
      borderData: FlBorderData(show: false),
      titlesData: FlTitlesData(
        topTitles:
            const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles:
            const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 46,
            interval: yStep <= 0 ? null : yStep,
            getTitlesWidget: (v, _) => Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Text(_compact(v),
                  maxLines: 1, style: AppTextStyles.micro),
            ),
          ),
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 24,
            interval: 1,
            getTitlesWidget: (v, _) {
              final i = v.round();
              if (i < 0 || i >= n || i % xStep != 0) {
                return const SizedBox.shrink();
              }
              return Padding(
                padding: const EdgeInsets.only(top: 7),
                child: Text(report.labels[i], style: AppTextStyles.micro),
              );
            },
          ),
        ),
      ),
      lineTouchData: LineTouchData(
        touchTooltipData: LineTouchTooltipData(
          getTooltipColor: (_) => cs.onSurface,
          tooltipRoundedRadius: 8,
          getTooltipItems: (spots) => [
            for (final s in spots)
              LineTooltipItem(
                '${shown[s.barIndex].label} : '
                '${CurrencyFormatter.format(s.y)}',
                AppTextStyles.microBold.copyWith(color: cs.surface),
              ),
          ],
        ),
      ),
      lineBarsData: [
        for (final c in shown)
          LineChartBarData(
            spots: [
              for (var i = 0; i < n; i++)
                FlSpot(i.toDouble(), series[c]![i]),
            ],
            isCurved: true,
            curveSmoothness: 0.28,
            preventCurveOverShooting: true,
            color: c.color,
            barWidth: 2,
            dotData: const FlDotData(show: false),
          ),
      ],
    );
  }
}

/// Puce d'activation d'une courbe : pastille de couleur + libellé.
class _CurveChip extends StatelessWidget {
  final _Curve curve;
  final bool selected;
  final VoidCallback onTap;

  const _CurveChip({
    required this.curve,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem = theme.semantic;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(9),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? curve.color.withValues(alpha: 0.12)
              : sem.trackMuted,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: selected ? curve.color : sem.borderSubtle,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                // Puce éteinte : pastille creuse, la couleur reste lisible
                // sans prétendre que la courbe est tracée.
                color: selected ? curve.color : Colors.transparent,
                shape: BoxShape.circle,
                border: Border.all(color: curve.color, width: 1.5),
              ),
            ),
            const SizedBox(width: 7),
            Text(curve.label,
                style: AppTextStyles.bodySm.copyWith(
                  color: theme.colorScheme.onSurface
                      .withValues(alpha: selected ? 1 : 0.55),
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                )),
          ],
        ),
      ),
    );
  }
}

/// Puce de sélection simple (secteur).
class _Choice extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _Choice({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem = theme.semantic;
    final cs = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(9),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? cs.primary.withValues(alpha: 0.12)
              : sem.trackMuted,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: selected ? cs.primary : sem.borderSubtle,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Text(label,
            style: AppTextStyles.bodySm.copyWith(
              color: selected ? cs.primary : cs.onSurface,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            )),
      ),
    );
  }
}

/// Résumé par secteur d'activité : ventes · matières · marge · taux.
///
/// S'efface complètement tant qu'aucune activité n'a vendu : une table à une
/// seule ligne « Sans secteur » ne dirait rien de plus que le bandeau du haut.
class _SectorCard extends StatelessWidget {
  final RestaurantFinanceReport report;
  const _SectorCard({required this.report});

  @override
  Widget build(BuildContext context) {
    final sectors = report.sectors;
    if (!sectors.any((s) => s.activityId != null)) {
      return const SizedBox.shrink();
    }
    final cs = Theme.of(context).colorScheme;
    final maxRevenue = sectors.fold<double>(
        0, (m, s) => s.revenue > m ? s.revenue : m);

    return _Card(
      title: 'Par secteur',
      subtitle: 'Ventes et marge brute de chaque activité',
      child: Column(
        children: [
          for (final s in sectors)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(s.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTextStyles.bodyBold
                                .copyWith(color: cs.onSurface)),
                      ),
                      Text(CurrencyFormatter.format(s.revenue),
                          style: AppTextStyles.bodyBold
                              .copyWith(color: cs.onSurface)),
                    ],
                  ),
                  const SizedBox(height: 5),
                  // Barre de part relative : compare les secteurs d'un coup
                  // d'œil sans avoir à lire les montants.
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: maxRevenue <= 0 ? 0 : s.revenue / maxRevenue,
                      minHeight: 6,
                      backgroundColor: Theme.of(context).semantic.trackMuted,
                      valueColor: const AlwaysStoppedAnimation<Color>(
                          RestoSeriesColors.sales),
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                      'Matières ${CurrencyFormatter.format(s.materialCost)} · '
                      'Marge ${CurrencyFormatter.format(s.margin)} '
                      '(${s.marginRate.toStringAsFixed(0)} %)',
                      style: AppTextStyles.caption),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Montant compact pour l'axe vertical (12 500 → « 13k »).
String _compact(double v) {
  final a = v.abs();
  if (a >= 1000000) {
    return '${(v / 1000000).toStringAsFixed(a >= 10000000 ? 0 : 1)}M';
  }
  if (a >= 1000) return '${(v / 1000).toStringAsFixed(0)}k';
  return v.toStringAsFixed(0);
}

/// Répartition des commandes par canal de service, en anneau + légende.
class _ChannelCard extends ConsumerWidget {
  final RestaurantDashData resto;
  const _ChannelCard({required this.resto});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sem = Theme.of(context).semantic;
    final cs = Theme.of(context).colorScheme;
    final period = ref.watch(dashPeriodProvider);

    final slices = <({String label, int count, Color color})>[
      (label: 'Salle', count: resto.dineIn, color: RestoTileColors.average),
      (
        label: 'À emporter',
        count: resto.takeaway,
        color: RestoTileColors.orders
      ),
      (
        label: 'Livraison',
        count: resto.delivery,
        color: RestoTileColors.expense
      ),
    ];

    return _Card(
      title: 'Répartition des commandes',
      subtitle: _periodLabel(period),
      // Sélecteur de période CANONIQUE de l'app (mode pastille) : il pilote
      // `dashPeriodProvider`, donc les tuiles du haut suivent le même choix
      // sans qu'on ait à recâbler quoi que ce soit.
      trailing: const PeriodSelector(mode: PeriodSelectorMode.inline),
      child: resto.totalOrders == 0
          ? const _EmptyBlock(
              icon: Icons.donut_large_rounded,
              message: 'Aucune commande encaissée sur cette période.',
            )
          : Row(
              children: [
                SizedBox(
                  width: 150,
                  height: 150,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      PieChart(PieChartData(
                        sections: [
                          for (final s in slices)
                            if (s.count > 0)
                              PieChartSectionData(
                                value: s.count.toDouble(),
                                color: s.color,
                                radius: 26,
                                showTitle: false,
                              ),
                        ],
                        centerSpaceRadius: 46,
                        sectionsSpace: 3,
                        borderData: FlBorderData(show: false),
                        startDegreeOffset: -90,
                      )),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('${resto.totalOrders}',
                              style: AppTextStyles.display
                                  .copyWith(color: cs.onSurface)),
                          Text('commandes', style: AppTextStyles.micro),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final s in slices)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 7),
                          child: Row(
                            children: [
                              Container(
                                width: 13,
                                height: 13,
                                decoration: BoxDecoration(
                                  color: s.color,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                              const SizedBox(width: 9),
                              Expanded(
                                child: Text(s.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppTextStyles.body
                                        .copyWith(color: cs.onSurface)),
                              ),
                              Text(
                                '${resto.pctOf(s.count).toStringAsFixed(0)}%',
                                style: AppTextStyles.bodyBold
                                    .copyWith(color: cs.onSurface),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 4),
                      Text('sur ${resto.totalOrders} commandes encaissées',
                          style: AppTextStyles.micro
                              .copyWith(color: sem.borderSubtle)),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

/// Activité des 7 derniers jours, en barres, jour courant mis en avant.
class _WeekChart extends StatelessWidget {
  final RestaurantDashData resto;
  const _WeekChart({required this.resto});

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    final cs = Theme.of(context).colorScheme;
    final counts = resto.ordersByWeekday;
    final maxVal = counts.fold<int>(0, (m, v) => v > m ? v : m);
    final todayIdx = (DateTime.now().weekday - 1) % 7;
    // clamp() sur un double renvoie  — cast explicite requis par les
    // paramètres  de fl_chart, typés double.
    final step = (maxVal / 4).ceilToDouble().clamp(1.0, double.infinity);

    return _Card(
      title: 'Activité de la semaine',
      // Pastille SANS chevron : la fenêtre est fixe à 7 jours (un histogramme
      // par jour de semaine n'a pas de sens au-delà), donc pas de faux
      // contrôle qui laisserait croire à un choix.
      trailing: const RestoPeriodPill(label: '7 jours'),
      child: maxVal == 0
          ? const _EmptyBlock(
              icon: Icons.bar_chart_rounded,
              message: 'Aucune commande sur les 7 derniers jours.',
            )
          : SizedBox(
              height: 196,
              child: BarChart(BarChartData(
                // Marge haute généreuse : la valeur est affichée AU-DESSUS
                // de la barre du jour, elle ne doit pas être tronquée.
                maxY: (maxVal * 1.32).ceilToDouble(),
                alignment: BarChartAlignment.spaceAround,
                gridData: const FlGridData(show: false),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 30,
                      interval: step,
                      getTitlesWidget: (v, _) => Text(
                        v.toInt().toString(),
                        style: AppTextStyles.micro,
                      ),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 24,
                      getTitlesWidget: (v, _) {
                        final i = v.toInt();
                        if (i < 0 || i >= kWeekdayLabels.length) {
                          return const SizedBox.shrink();
                        }
                        return Padding(
                          padding: const EdgeInsets.only(top: 7),
                          child: Text(
                            kWeekdayLabels[i],
                            style: i == todayIdx
                                ? AppTextStyles.bodySmBold
                                    .copyWith(color: cs.onSurface)
                                : AppTextStyles.bodySm,
                          ),
                        );
                      },
                    ),
                  ),
                ),
                barTouchData: BarTouchData(
                  touchTooltipData: BarTouchTooltipData(
                    getTooltipColor: (_) => cs.onSurface,
                    tooltipRoundedRadius: 8,
                    getTooltipItem: (g, gi, rod, ri) => BarTooltipItem(
                      '${rod.toY.toInt()} commande'
                      '${rod.toY.toInt() > 1 ? 's' : ''}',
                      AppTextStyles.microBold.copyWith(color: cs.surface),
                    ),
                  ),
                ),
                barGroups: [
                  for (var i = 0; i < counts.length; i++)
                    BarChartGroupData(x: i, barRods: [
                      BarChartRodData(
                        toY: counts[i].toDouble(),
                        color: i == todayIdx
                            ? RestoTileColors.revenue
                            : sem.trackMuted,
                        width: 17,
                        borderRadius: BorderRadius.circular(5),
                      ),
                    ], showingTooltipIndicators: i == todayIdx ? [0] : []),
                ],
              )),
            ),
    );
  }
}

/// Plats les plus vendus, en carrousel avec flèches.
class _TrendingCard extends StatefulWidget {
  final String shopId;
  final List<TopProd> top;

  const _TrendingCard({required this.shopId, required this.top});

  @override
  State<_TrendingCard> createState() => _TrendingCardState();
}

class _TrendingCardState extends State<_TrendingCard> {
  final _ctrl = ScrollController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// Défile d'une carte entière (largeur + gouttière).
  void _scroll(int direction) {
    if (!_ctrl.hasClients) return;
    final target = (_ctrl.offset + direction * 236)
        .clamp(0.0, _ctrl.position.maxScrollExtent);
    _ctrl.animateTo(target,
        duration: const Duration(milliseconds: 260), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    final cs = Theme.of(context).colorScheme;
    final top = widget.top;

    return _Card(
      title: 'Plats qui marchent',
      trailing: top.isEmpty
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ArrowBtn(
                    icon: Icons.chevron_left_rounded,
                    onTap: () => _scroll(-1)),
                const SizedBox(width: 6),
                _ArrowBtn(
                    icon: Icons.chevron_right_rounded,
                    onTap: () => _scroll(1)),
              ],
            ),
      child: top.isEmpty
          ? const _EmptyBlock(
              icon: Icons.restaurant_rounded,
              message: 'Aucune vente sur cette période.',
            )
          : SizedBox(
              height: 208,
              child: ListView.separated(
                controller: _ctrl,
                scrollDirection: Axis.horizontal,
                itemCount: top.length,
                separatorBuilder: (_, __) => const SizedBox(width: 14),
                itemBuilder: (_, i) {
                  final p = top[i];
                  return Container(
                    width: 222,
                    decoration: BoxDecoration(
                      color: sem.elevatedSurface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: sem.borderSubtle),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          height: 150,
                          width: double.infinity,
                          child: ProductImageCard(
                            imageUrl: p.imageUrl,
                            fillParent: true,
                            borderRadius: BorderRadius.zero,
                          ),
                        ),
                        Expanded(
                          child: Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 11),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    p.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppTextStyles.bodySm
                                        .copyWith(color: cs.onSurface),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Vendus : ${p.qty}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTextStyles.bodySmBold
                                      .copyWith(color: cs.onSurface),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
    );
  }
}

/// Bouton rond de défilement du carrousel.
class _ArrowBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _ArrowBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.semantic.trackMuted,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Icon(icon, size: 20, color: theme.colorScheme.onSurface),
        ),
      ),
    );
  }
}

/// Carte de section — titre, sous-titre, contrôle à droite.
class _Card extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;

  const _Card({
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem = theme.semantic;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: sem.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: AppTextStyles.subtitleBold
                            .copyWith(color: theme.colorScheme.onSurface)),
                    if (subtitle != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(subtitle!,
                            style: AppTextStyles.bodySmSecondary),
                      ),
                  ],
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

/// État vide, à hauteur constante pour que la page ne saute pas au chargement.
class _EmptyBlock extends StatelessWidget {
  final IconData icon;
  final String message;

  const _EmptyBlock({required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 150,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 32, color: cs.onSurface.withValues(alpha: 0.25)),
            const SizedBox(height: 8),
            Text(message,
                textAlign: TextAlign.center,
                style: AppTextStyles.bodySmSecondary),
          ],
        ),
      ),
    );
  }
}

/// Deux cartes côte à côte sur large écran, empilées sinon.
class _TwoCol extends StatelessWidget {
  final Widget first;
  final Widget second;

  const _TwoCol({required this.first, required this.second});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (_, c) => c.maxWidth >= 860
            ? IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: first),
                    const SizedBox(width: 16),
                    Expanded(child: second),
                  ],
                ),
              )
            : Column(
                children: [first, const SizedBox(height: 16), second],
              ),
      );
}

/// Libellé long de la période, affiché en sous-titre.
String _periodLabel(DashPeriod p) => switch (p) {
      DashPeriod.today     => 'Aujourd\'hui',
      DashPeriod.yesterday => 'Hier',
      DashPeriod.week      => 'Cette semaine',
      DashPeriod.month     => 'Ce mois-ci',
      DashPeriod.quarter   => 'Ce trimestre',
      DashPeriod.year      => 'Cette année',
      DashPeriod.custom    => 'Période personnalisée',
    };
