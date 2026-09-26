part of 'restaurant_dashboard_page.dart';

// Les finances : indicateurs, food cost, courbes, secteurs.

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

/// CE QU'ON MONTRE À LA PLACE D'UNE MARGE QUI NE VEUT RIEN DIRE.
///
/// Un vide silencieux ferait croire à une panne : le gérant changerait de
/// période, ne comprendrait pas, et finirait par douter de l'application. La
/// carte dit la MÉCANIQUE — et explique du même coup pourquoi son food cost
/// bougeait tant d'un jour à l'autre avant qu'on la retire.
class _MarginsUnavailableCard extends StatelessWidget {
  const _MarginsUnavailableCard();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: restoCardSurface(context, radius: 14),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.calendar_month_outlined,
            size: 19, color: cs.onSurface.withValues(alpha: 0.45)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(marginsUnavailableReason,
              style: AppTextStyles.bodySmSecondary),
        ),
      ]),
    );
  }
}

/// Bandeau financier : ventes, bénéfice net, dépenses, pertes de la période.
///
/// Les couleurs sont celles des courbes du graphique juste en dessous : une
/// pastille verte ici = la courbe verte là.
///
/// BÉNÉFICE, DÉPENSES ET PERTES SONT MASQUÉS À L'OUVERTURE. Le tableau de bord
/// vit sur une tablette de salle, à portée de regard des clients et de toute
/// l'équipe ; ce que gagne l'établissement n'a pas à s'afficher en continu. Ils
/// se révèlent d'un geste, et se remasquent au prochain passage.
///
/// Les VENTES restent visibles : c'est l'indicateur de service, celui qu'on
/// consulte en salle, et il ne dit rien de la rentabilité.
class _FinanceKpiRow extends StatefulWidget {
  final RestaurantFinanceReport report;
  const _FinanceKpiRow({required this.report});

  @override
  State<_FinanceKpiRow> createState() => _FinanceKpiRowState();
}

class _FinanceKpiRowState extends State<_FinanceKpiRow> {
  /// Volontairement NON persisté : le masquage doit être l'état par défaut à
  /// chaque ouverture. Mémoriser « affiché » reviendrait à ne masquer qu'une
  /// fois, ce qui ne protège rien.
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    final report = widget.report;
    final cs = Theme.of(context).colorScheme;
    final tiles = <Widget>[
      _FinanceTile(curve: _Curve.sales, amount: report.revenue),
      _FinanceTile(
        curve: _Curve.profit,
        amount: report.netProfit,
        // La marge brute contextualise le bénéfice : un bénéfice net faible
        // avec une marge brute élevée désigne les charges, pas la carte.
        hint: 'Marge brute ${report.marginRate.toStringAsFixed(0)} %',
        hidden: !_revealed,
        onTap: () => setState(() => _revealed = !_revealed),
      ),
      _FinanceTile(
        curve: _Curve.expense,
        amount: report.expenses,
        // « dont matières » suit la même règle que le bénéfice : les achats
        // réels dès qu'ils sont saisis, l'estimation des recettes sinon.
        // « estimée » quand la paie vient des contrats et non des fiches :
        // sans ce mot, un bénéfice bâti sur une approximation se lit comme un
        // bénéfice arrêté. Le chiffre bougera à l'établissement des fiches —
        // vers le haut avec les primes, vers le bas avec les absences.
        hint: 'dont matières '
            '${CurrencyFormatter.format(report.foodCost)}'
            '${report.payroll > 0 ? ' · paie ${CurrencyFormatter.format(report.payroll.toDouble())}'
                '${report.payrollEstimated ? ' estimée' : ''}' : ''}',
        hidden: !_revealed,
        onTap: () => setState(() => _revealed = !_revealed),
      ),
      _FinanceTile(
        curve: _Curve.loss,
        amount: report.losses.toDouble(),
        hidden: !_revealed,
        onTap: () => setState(() => _revealed = !_revealed),
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          Expanded(
            child: Text(
                _revealed
                    ? 'Résultat financier'
                    : 'Résultat financier — masqué',
                style: AppTextStyles.bodySmBold
                    .copyWith(color: cs.onSurface.withValues(alpha: 0.7))),
          ),
          TextButton.icon(
            onPressed: () => setState(() => _revealed = !_revealed),
            icon: Icon(
                _revealed
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                size: 16),
            label: Text(_revealed ? 'Masquer' : 'Afficher'),
          ),
        ]),
        const SizedBox(height: 4),
        LayoutBuilder(builder: (_, c) {
          final wide = c.maxWidth >= kRestoKpiFourColumnsMin;
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
        }),
      ],
    );
  }
}

/// Carte FOOD COST (Lot E) — l'indicateur de survie d'un restaurant.
///
/// Le food cost est la part du chiffre d'affaires qui repart en matières
/// premières. Au-delà de 35 %, la carte ne dégage plus assez pour couvrir le
/// loyer et les salaires : c'est le premier chiffre qu'un restaurateur doit
/// voir, avant même son bénéfice.
///
/// Deux mesures cohabitent, et leur ÉCART est le vrai signal :
///   * le THÉORIQUE vient des fiches recettes — ce que les plats vendus
///     auraient dû consommer ;
///   * le RÉEL vient des achats saisis — ce qui est réellement sorti.
/// Un réel durablement supérieur au théorique, c'est du gaspillage, du vol, ou
/// une fiche recette fausse.
class _FoodCostCard extends StatelessWidget {
  final RestaurantFinanceReport report;
  const _FoodCostCard({required this.report});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem = theme.semantic;
    final level = report.foodCostLevel;
    // Pas de vente sur la période : un taux sans chiffre d'affaires ne veut
    // rien dire, on n'affiche pas une pastille rouge trompeuse.
    if (level == null) return const SizedBox.shrink();

    final color = switch (level) {
      'good' => sem.success,
      'warning' => sem.warning,
      _ => sem.danger,
    };
    final rate = report.foodCostRate;

    return Container(
      padding: const EdgeInsets.all(14),
      // Arête haute teintée du NIVEAU de food cost : la carte s'annonce avant
      // d'être lue. Vert, orange ou rouge selon le seuil franchi.
      decoration: restoCardSurface(context, radius: 14).copyWith(
        border: Border(
          top: BorderSide(color: color.withValues(alpha: 0.55), width: 2),
          left: BorderSide(color: restoGlassBorder(context), width: 0.5),
          right: BorderSide(color: restoGlassBorder(context), width: 0.5),
          bottom: BorderSide(color: restoGlassBorder(context), width: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.restaurant_menu_rounded, size: 18, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Food cost', style: AppTextStyles.bodyBold),
              ),
              Text('${rate.toStringAsFixed(1)} %',
                  style:
                      AppTextStyles.title.copyWith(color: sem.textFor(color))),
            ],
          ),
          const SizedBox(height: 6),
          // Barre de niveau : la position par rapport aux seuils se lit plus
          // vite qu'un pourcentage.
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: (rate / 50).clamp(0.0, 1.0),
              minHeight: 6,
              backgroundColor: sem.trackMuted,
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
          const SizedBox(height: 6),
          Text(
              switch (level) {
                'good' => 'Sous les 30 % — bonne maîtrise des matières.',
                'warning' =>
                  'Entre 30 et 35 % — surveillez les portions et les pertes.',
                _ => 'Au-dessus de 35 % — la carte ne couvre plus ses charges.',
              },
              style: AppTextStyles.captionHint),
          const Divider(height: 20),
          Row(
            children: [
              Expanded(
                child: _FoodCostSide(
                  label: report.usesRealFoodCost ? 'Réel (achats)' : 'Estimé',
                  amount: report.foodCost,
                  rate: report.foodCostRate,
                  strong: true,
                ),
              ),
              if (report.usesRealFoodCost)
                Expanded(
                  child: _FoodCostSide(
                    label: 'Théorique (recettes)',
                    amount: report.materialCost,
                    rate: report.theoreticalFoodCostRate,
                  ),
                ),
            ],
          ),
          // ÉCART ACHATS / CONSOMMATION, DÉCOMPOSÉ.
          //
          // En répartition, le coût théorique est dérivé des achats eux-mêmes :
          // l'écart ne peut pas mesurer le gaspillage, qui est déjà sorti en
          // pertes. Ce qui reste est du NON-RATTACHEMENT — des achats qu'aucun
          // plat vendu ne consomme. Annoncer « gaspillage ou fiche à revoir »
          // envoyait le gérant chercher un coupable là où il suffisait de
          // cocher un ingrédient.
          if (report.usesRealFoodCost && report.gapFromUnallocated > 0) ...[
            const SizedBox(height: 6),
            Text(
                '${CurrencyFormatter.format(report.gapFromUnallocated)} '
                'd\'achats ne sont rattachés à aucun plat vendu : un '
                'ingrédient dont aucune recette ne se sert, ou un plat retiré '
                'de la carte.',
                style: AppTextStyles.caption.copyWith(color: sem.warningText)),
          ],
          // Ce qui RESTE une fois le non-rattaché nommé. Là, et seulement là,
          // les trois causes historiques gardent leur sens.
          if (report.usesRealFoodCost &&
              report.gapBeyondUnallocated.abs() > 0) ...[
            const SizedBox(height: 6),
            Text(
                report.gapBeyondUnallocated > 0
                    ? 'Vous avez acheté '
                        '${CurrencyFormatter.format(report.gapBeyondUnallocated)} '
                        'de plus que ce que vos ventes ont consommé — stock '
                        'constitué, gaspillage ou fiche recette à revoir.'
                    : 'Vous avez consommé '
                        '${CurrencyFormatter.format(-report.gapBeyondUnallocated)} '
                        'de plus que vos achats de la période — vous puisez '
                        'dans le stock existant.',
                style: AppTextStyles.caption.copyWith(
                    color:
                        report.gapBeyondUnallocated > 0 ? sem.warningText : null)),
          ],
          if (!report.usesRealFoodCost) ...[
            const SizedBox(height: 6),
            Text(
                'Estimé d\'après vos fiches recettes. Saisissez vos achats '
                'dans Finances → Dépenses pour obtenir le coût réel.',
                style: AppTextStyles.captionHint),
          ],
          // COUVERTURE DU TAUX — un indicateur ne doit pas rassurer parce
          // qu'il manque des données. Le taux ne porte que sur les ventes dont
          // le coût est connu ; sans ce message, il se lirait comme portant sur
          // toute la carte, et serait d'autant plus vert que le restaurant en
          // sait moins sur ses coûts.
          if (report.costCoverage < 0.999) ...[
            const SizedBox(height: 6),
            Text(
                'Ce taux ne porte que sur '
                '${(report.costCoverage * 100).round()} % de vos ventes : '
                'le reste vient de plats dont le coût matière n\'est pas '
                'renseigné.',
                style: AppTextStyles.caption.copyWith(color: sem.warningText)),
          ],
        ],
      ),
    );
  }
}

/// Un côté de la comparaison food cost (réel / théorique).
class _FoodCostSide extends StatelessWidget {
  final String label;
  final double amount;
  final double rate;
  final bool strong;

  const _FoodCostSide({
    required this.label,
    required this.amount,
    required this.rate,
    this.strong = false,
  });

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppTextStyles.captionHint),
          Text(CurrencyFormatter.format(amount),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  strong ? AppTextStyles.bodyBold : AppTextStyles.bodySmBold),
          Text('${rate.toStringAsFixed(1)} % du CA',
              style: AppTextStyles.micro),
        ],
      );
}

/// Tuile d'indicateur financier : pastille de couleur de courbe + montant.
class _FinanceTile extends StatelessWidget {
  final _Curve curve;
  final double amount;
  final String? hint;

  /// Montant remplacé par des points. La tuile garde sa place et son libellé :
  /// on doit voir QU'IL Y A un bénéfice à consulter, pas sa valeur.
  final bool hidden;

  /// Révèle au toucher — la tuile masquée est elle-même l'interrupteur, plus
  /// direct que de viser le bouton d'en-tête.
  final VoidCallback? onTap;

  const _FinanceTile({
    required this.curve,
    required this.amount,
    this.hint,
    this.hidden = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final sem = theme.semantic;
    // Un bénéfice négatif se lit en rouge : c'est l'information la plus
    // importante de l'écran, elle ne doit pas se fondre dans le violet.
    //
    // JAMAIS quand la tuile est masquée : la couleur trahirait ce que les
    // points cachent. Un rectangle rouge dit « vous perdez de l'argent » aussi
    // clairement que le montant lui-même.
    final negative = !hidden && curve == _Curve.profit && amount < 0;

    return Container(
      decoration: restoCardSurface(context, radius: 14),
      child: Material(
        // Transparent : la couleur du Material masquerait la surface. Il ne
        // porte plus que l'encre du toucher.
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 6,
                height: 38,
                decoration: BoxDecoration(
                  color: negative
                      ? sem.danger
                      : (hidden
                          ? curve.color.withValues(alpha: 0.35)
                          : curve.color),
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
                        hidden ? '••• •••' : CurrencyFormatter.format(amount),
                        maxLines: 1,
                        style: AppTextStyles.title.copyWith(
                          color: negative
                              ? sem.dangerText
                              : cs.onSurface.withValues(
                                  alpha: hidden ? 0.45 : 1),
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      // L'indice est masqué avec le montant : « Marge brute
                      // 62 % » et « dont matières 93 400 F » en disent autant
                      // que le chiffre principal.
                      hidden ? curve.label : (hint ?? curve.label),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.bodySm
                          .copyWith(color: cs.onSurface.withValues(alpha: 0.6)),
                    ),
                  ],
                ),
              ),
              if (hidden)
                Icon(Icons.visibility_outlined,
                    size: 15, color: cs.onSurface.withValues(alpha: 0.35)),
            ],
          ),
        ),
        ),
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
                  style: AppTextStyles.bodySm.copyWith(color: Theme.of(context).semantic.brandText),
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
              // Le compact CANONIQUE (§ 14) : « 2,5k », pas « 3k » — la copie
              // locale arrondissait à l'entier et l'axe mentait sur un pas de
              // 2 500. Le bénéfice peut être négatif : le signe est géré.
              child: Text(CurrencyFormatter.compact(v),
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
              color: selected ? Theme.of(context).semantic.brandText : cs.onSurface,
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
