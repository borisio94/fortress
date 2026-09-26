import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../dashboard/data/dashboard_providers.dart';
import '../../domain/margin_window.dart';
import '../../domain/period_coverage.dart';
import 'resto_dashed_border.dart';
import 'resto_kpi_tile.dart';

// Sélecteur de période du tableau de bord restaurant.
//
// PROPRE AU RESTAURANT, et non une variante de `PeriodSelector` : le widget
// partagé sert aussi la page Finances e-commerce, qui n'a pas de règle de
// marge. Il pilote en revanche les MÊMES providers (`dashPeriodProvider`,
// `dashCustomRangeProvider`) : tout ce qui les lit suit le choix.
//
// Ce que la feuille dit AVANT qu'on choisisse — c'est tout son objet :
//   • ce que chaque période couvre, en dates (« Mois → 1er → 24 sept. ») ;
//   • si elle porte des marges, par la famille où elle est rangée.
// La conséquence du choix ne se découvre plus après coup, en voyant les
// indicateurs financiers disparaître.

/// Périodes proposées, dans l'ordre. Le trimestre n'y figure pas : il n'était
/// pas proposé avant et vaut quatre-vingt-dix jours glissants, une fenêtre
/// qu'aucun gérant ne demande.
const _presets = [
  DashPeriod.today,
  DashPeriod.yesterday,
  DashPeriod.week,
  DashPeriod.month,
  DashPeriod.year,
];

/// Nom court, celui du bouton et de la ligne de la feuille.
String restoPeriodName(DashPeriod p) => switch (p) {
      DashPeriod.today     => 'Aujourd\'hui',
      DashPeriod.yesterday => 'Hier',
      DashPeriod.week      => 'Semaine',
      DashPeriod.month     => 'Mois',
      DashPeriod.quarter   => 'Trimestre',
      DashPeriod.year      => 'Année',
      DashPeriod.custom    => 'Personnalisé',
    };

typedef _Choice = ({DashPeriod period, DashRange? custom});

String _short(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';

/// Le bouton, posé en haut à droite de l'écran.
class RestoPeriodButton extends ConsumerWidget {
  /// Portée du choix, en sous-titre de la feuille. La période est UNE pour
  /// tout le module (`dashPeriodProvider`) : chaque écran dit jusqu'où elle
  /// porte depuis l'endroit où on la change.
  final String scope;

  const RestoPeriodButton({
    super.key,
    this.scope = 'S\'applique à tout le tableau de bord',
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final period = ref.watch(dashPeriodProvider);
    final custom = ref.watch(dashCustomRangeProvider);
    final label = period == DashPeriod.custom && custom != null
        ? '${_short(custom.from)} – ${_short(custom.to)}'
        : restoPeriodName(period);
    return RestoPeriodPill(
      label: label,
      onTap: () => _open(context, ref, scope),
    );
  }

  static Future<void> _open(
      BuildContext context, WidgetRef ref, String scope) async {
    final choice = await showAdaptiveFormSheet<_Choice>(
      context: context,
      builder: (_) => _PeriodSheet(
        scope: scope,
        current: ref.read(dashPeriodProvider),
        custom: ref.read(dashCustomRangeProvider),
      ),
    );
    if (choice == null) return;
    ref.read(dashPeriodProvider.notifier).state = choice.period;
    ref.read(dashCustomRangeProvider.notifier).state = choice.custom;
  }
}

// ─── Feuille : deux familles, une option par ligne ──────────────────────────

class _PeriodSheet extends StatelessWidget {
  final String scope;
  final DashPeriod current;
  final DashRange? custom;

  const _PeriodSheet({
    required this.scope,
    required this.current,
    required this.custom,
  });

  Future<void> _openCustom(BuildContext context) async {
    final range = await showAdaptiveFormSheet<DashRange>(
      context: context,
      builder: (_) => _CustomRangeScreen(initial: custom),
    );
    if (range == null || !context.mounted) return;
    Navigator.of(context)
        .pop<_Choice>((period: DashPeriod.custom, custom: range));
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    // LE CLASSEMENT VIENT DE LA RÈGLE, il n'est pas recopié ici : si
    // `marginsMakeSenseOn` change, les familles suivent d'elles-mêmes.
    final volumesOnly = <DashPeriod>[];
    final withMargins = <DashPeriod>[];
    for (final p in _presets) {
      (marginsMakeSenseOn(p, rangeFor(p)) ? withMargins : volumesOnly).add(p);
    }

    Widget row(DashPeriod p) => _OptionRow(
          name: restoPeriodName(p),
          coverage: periodCoverage(p, rangeFor(p), now: now),
          selected: p == current,
          onTap: () => Navigator.of(context)
              .pop<_Choice>((period: p, custom: null)),
        );

    final customRange = current == DashPeriod.custom ? custom : null;

    return AdaptiveFormFrame(
      title: 'Période',
      subtitle: scope,
      icon: Icons.calendar_month_outlined,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _FamilyHeader(
              title: 'VOLUMES SEULEMENT',
              hint: 'Ventes, commandes et pertes. Pas de marge : sur moins '
                  'd\'un mois, les achats ne se répartissent pas assez.',
            ),
            for (final p in volumesOnly) ...[row(p), const SizedBox(height: 6)],
            const SizedBox(height: 14),
            const _FamilyHeader(
              title: 'VOLUMES ET MARGES',
              hint: 'Tout, y compris bénéfice, marge brute et food cost.',
            ),
            for (final p in withMargins) ...[row(p), const SizedBox(height: 6)],
            const SizedBox(height: 14),
            _CustomRow(
              selected: customRange != null,
              detail: customRange == null
                  ? 'Deux dates de votre choix'
                  : formatCoverageRange(
                      rangeFor(DashPeriod.custom,
                          customFrom: customRange.from,
                          customTo: customRange.to),
                      now: now),
              onTap: () => _openCustom(context),
            ),
          ],
        ),
      ),
    );
  }
}

class _FamilyHeader extends StatelessWidget {
  final String title;
  final String hint;

  const _FamilyHeader({required this.title, required this.hint});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8, left: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: AppTextStyles.microBold.copyWith(
                    letterSpacing: 0.8,
                    color: Theme.of(context).colorScheme.onSurface)),
            const SizedBox(height: 2),
            Text(hint, style: AppTextStyles.caption),
          ],
        ),
      );
}

/// Une option, sur TOUTE la largeur : nom à gauche, couverture à droite.
///
/// Une par ligne et non des pastilles côte à côte : dans un `Wrap`, « Année »
/// se coupait et « Personnalisé » partait seul sur une seconde ligne — et la
/// couverture n'aurait eu aucune place.
class _OptionRow extends StatelessWidget {
  final String name;
  final String coverage;
  final bool selected;
  final VoidCallback onTap;

  const _OptionRow({
    required this.name,
    required this.coverage,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    return Material(
      color: selected ? cs.primary.withValues(alpha: 0.08) : cs.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
            color: selected ? cs.primary : sem.borderSubtle,
            width: selected ? 1.4 : 1),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(children: [
            Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 18,
                color: selected
                    ? cs.primary
                    : cs.onSurface.withValues(alpha: 0.4)),
            const SizedBox(width: 10),
            Text(name,
                style: (selected ? AppTextStyles.bodyBold : AppTextStyles.body)
                    .copyWith(color: cs.onSurface)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(coverage,
                  textAlign: TextAlign.end,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.bodySmSecondary),
            ),
          ]),
        ),
      ),
    );
  }
}

/// « Personnalisé » : contour pointillé et chevron. Il ne se CHOISIT pas, il
/// s'OUVRE — la forme le dit avant qu'on touche.
class _CustomRow extends StatelessWidget {
  final bool selected;
  final String detail;
  final VoidCallback onTap;

  const _CustomRow({
    required this.selected,
    required this.detail,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    final accent = selected ? cs.primary : cs.onSurface;
    return RestoDashedBorder(
      color: selected ? cs.primary : sem.borderSubtle,
      radius: 10,
      child: Material(
        color: selected ? cs.primary.withValues(alpha: 0.08) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(children: [
              Icon(Icons.date_range_rounded, size: 18, color: accent),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Personnalisé',
                        style: (selected
                                ? AppTextStyles.bodyBold
                                : AppTextStyles.body)
                            .copyWith(color: cs.onSurface)),
                    Text(detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.caption),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  size: 20, color: cs.onSurface.withValues(alpha: 0.6)),
            ]),
          ),
        ),
      ),
    );
  }
}

// ─── Second écran : la période libre ────────────────────────────────────────

/// Deux dates, et ce qu'elles donneront.
///
/// La période libre est la seule dont la famille dépend de la LONGUEUR (cf.
/// `marginsMakeSenseOn`) : on l'annonce donc en direct, pendant qu'on choisit
/// — « 12 jours · volumes seulement » avant de valider, pas après.
class _CustomRangeScreen extends StatefulWidget {
  final DashRange? initial;

  const _CustomRangeScreen({required this.initial});

  @override
  State<_CustomRangeScreen> createState() => _CustomRangeScreenState();
}

class _CustomRangeScreenState extends State<_CustomRangeScreen> {
  late DateTime _from;
  late DateTime _to;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    _from = widget.initial?.from ?? DateTime(now.year, now.month);
    _to = widget.initial?.to ?? today;
  }

  Future<void> _pick({required bool from}) async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: from ? _from : _to,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year, now.month, now.day),
    );
    if (d == null || !mounted) return;
    setState(() {
      if (from) {
        _from = d;
        if (_to.isBefore(_from)) _to = _from;
      } else {
        _to = d;
        if (_from.isAfter(_to)) _from = _to;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    final now = DateTime.now();
    final range =
        rangeFor(DashPeriod.custom, customFrom: _from, customTo: _to);
    final days = range.duration.inDays;
    final margins = marginsMakeSenseOn(DashPeriod.custom, range);
    final tone = margins ? sem.success : sem.warning;

    return AdaptiveFormFrame(
      title: 'Période personnalisée',
      subtitle: formatCoverageRange(range, now: now),
      icon: Icons.date_range_rounded,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(
                  child: _DateBox(
                      label: 'Du',
                      value: formatCoverageDay(_from, now: now),
                      onTap: () => _pick(from: true))),
              const SizedBox(width: 12),
              Expanded(
                  child: _DateBox(
                      label: 'Au (inclus)',
                      value: formatCoverageDay(_to, now: now),
                      onTap: () => _pick(from: false))),
            ]),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: tone.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: tone.withValues(alpha: 0.35)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                      margins
                          ? Icons.check_circle_outline_rounded
                          : Icons.info_outline_rounded,
                      size: 18,
                      color: tone),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                            '$days jour${days > 1 ? 's' : ''} · '
                            '${margins ? 'volumes et marges' : 'volumes seulement'}',
                            style: AppTextStyles.bodySmBold
                                .copyWith(color: cs.onSurface)),
                        if (!margins)
                          Text(
                              'Une marge demande au moins $kMinMarginDays '
                              'jours.',
                              style: AppTextStyles.caption),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      footer: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: SizedBox(
          height: 46,
          child: FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 46)),
            onPressed: () => Navigator.of(context).pop<DashRange>(
                DashRange(_from, _to)),
            child: const Text('Appliquer'),
          ),
        ),
      ),
    );
  }
}

class _DateBox extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback onTap;

  const _DateBox(
      {required this.label, required this.value, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    return Material(
      color: cs.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: sem.borderSubtle),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(children: [
            Icon(Icons.calendar_today_outlined, size: 16, color: cs.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: AppTextStyles.caption),
                  Text(value,
                      style: AppTextStyles.bodyBold
                          .copyWith(color: cs.onSurface)),
                ],
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
