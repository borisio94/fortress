import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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

    return AppScaffold(
      shopId: shopId,
      title: 'Tableau de bord',
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _KpiRow(shopId: shopId, data: data),
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
class _KpiRow extends StatelessWidget {
  final String shopId;
  final DashData data;

  const _KpiRow({required this.shopId, required this.data});

  @override
  Widget build(BuildContext context) {
    final symbol = CurrencyFormatter.currentSymbol;
    // Dépense moyenne PAR COMMANDE : rapporter les charges d'exploitation au
    // nombre de commandes est la seule lecture comparable au ticket moyen
    // affiché juste à côté.
    final avgExpense =
        data.orderCount > 0 ? data.operatingExpenses / data.orderCount : 0.0;

    final tiles = <Widget>[
      RestoKpiTile(
        value: '${CurrencyFormatter.compact(data.totalSales)} $symbol',
        label: 'Recette',
        icon: Icons.trending_up,
        color: RestoTileColors.revenue,
        onTap: () => context.push('/shop/$shopId/finances'),
      ),
      RestoKpiTile(
        value: data.orderCount.toString(),
        label: 'Commandes',
        icon: Icons.receipt_long_rounded,
        color: RestoTileColors.orders,
        onTap: () => context.push('/shop/$shopId/caisse/orders'),
      ),
      RestoKpiTile(
        value: '${CurrencyFormatter.compact(avgExpense)} $symbol',
        label: 'Dépense moy.',
        icon: Icons.account_balance_wallet_rounded,
        color: RestoTileColors.expense,
        onTap: () => context.push('/shop/$shopId/finances'),
      ),
      RestoKpiTile(
        value: '${CurrencyFormatter.compact(data.avgTicket)} $symbol',
        label: 'Ticket moyen',
        icon: Icons.payments_rounded,
        color: RestoTileColors.average,
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
                  // Prix moyen RÉELLEMENT encaissé : il intègre suppléments
                  // et remises, contrairement au prix catalogue.
                  final unit = p.qty > 0 ? p.revenue / p.qty : 0.0;
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
                                  'Prix : ${CurrencyFormatter.format(unit)}',
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
