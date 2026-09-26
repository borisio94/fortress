part of 'restaurant_dashboard_page.dart';

// L'activité : canaux, semaine, tendances, notation.

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
      // Plus de sélecteur ici : la période se choisit une fois, en tête
      // d'écran (`RestoPeriodButton`), et vaut pour toute la page.
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
      // La fenêtre est FIXE à 7 jours (un histogramme par jour de semaine n'a
      // pas de sens au-delà). Elle ne suit donc pas la période de la page, et
      // le sous-titre le dit — une pastille « 7 jours » à la place d'un
      // sélecteur ressemblait à un contrôle.
      subtitle: '7 derniers jours, quelle que soit la période',
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
                      color: restoGlassInner(context),
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
/// NOTATION DE L'ÉQUIPE — le classement du mois, meilleur en tête.
///
/// Cinq personnes au plus : au-delà, la carte devient une liste et le tableau
/// de bord cesse d'être un tableau de bord. Le lien mène à l'onglet complet.
///
/// Les employés SOUS LE SEUIL remontent en tête, avant le classement : c'est
/// l'information qui appelle une décision, et elle se perdrait au milieu d'un
/// palmarès trié par mérite — c'est-à-dire tout en bas.
class _StaffScoreCard extends StatefulWidget {
  final String shopId;
  const _StaffScoreCard({required this.shopId});

  @override
  State<_StaffScoreCard> createState() => _StaffScoreCardState();
}

class _StaffScoreCardState extends RestoTableListenerState<_StaffScoreCard> {
  @override
  List<String> get tables => const ['staff_ratings', 'employees'];
  @override
  String get shopId => widget.shopId;

  static const int _maxRows = 5;

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    final ranking = StaffScoreService.ranking(widget.shopId);
    if (ranking.isEmpty) return const SizedBox.shrink();

    final urgent = ranking.where((e) => e.score.needsReplacement).toList();
    final shown = ranking.take(_maxRows).toList();

    return _Card(
      title: 'Notation de l\'équipe',
      subtitle: urgent.isEmpty
          ? 'Chacun démarre le mois à ${StaffScore.baseScore} points'
          : '${urgent.length} à remplacer d\'urgence',
      trailing: TextButton(
        onPressed: () =>
            context.push('/shop/${widget.shopId}/restaurant/personnel'),
        child: const Text('Voir tout'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (urgent.isNotEmpty) ...[
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: sem.danger.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: sem.danger.withValues(alpha: 0.35)),
              ),
              child: Row(children: [
                Icon(Icons.warning_amber_rounded, size: 16, color: sem.danger),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                      urgent.map((e) => e.member.fullName).join(', '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.bodySm.copyWith(color: sem.dangerText)),
                ),
              ]),
            ),
          ],
          const SizedBox(height: 10),
          for (var i = 0; i < shown.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  SizedBox(
                    width: 22,
                    child: i == 0
                        ? const Icon(Icons.emoji_events_rounded,
                            size: 16, color: kRestoPodiumGold)
                        : Text('${i + 1}',
                            style: AppTextStyles.micro),
                  ),
                  Expanded(
                    flex: 4,
                    child: Text(shown[i].member.fullName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.bodySm),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 5,
                    child: StaffScoreGauge(score: shown[i].score, dense: true),
                  ),
                ],
              ),
            ),
          if (ranking.length > _maxRows)
            Text('+ ${ranking.length - _maxRows} autre'
                '${ranking.length - _maxRows > 1 ? 's' : ''}',
                style: AppTextStyles.micro),
        ],
      ),
    );
  }
}
