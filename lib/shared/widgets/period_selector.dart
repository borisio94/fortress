import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/app_localizations.dart';
import '../../core/theme/app_colors.dart';
import '../../features/dashboard/data/dashboard_providers.dart';

// ═════════════════════════════════════════════════════════════════════════════
// PeriodSelector — composant unique pour filtrer une période.
//
// Deux modes d'affichage :
//   • Mode.chips    → rangée horizontale de pills (today/yesterday/week/…).
//                     Custom ouvre le bottom sheet.
//   • Mode.inline   → bouton unique affichant la période courante, ouvre le
//                     bottom sheet au tap. Idéal pour l'en-tête d'un graph.
//
// Les deux modes pilotent les mêmes providers Riverpod :
//   `dashPeriodProvider` et `dashCustomRangeProvider`.
// Tout widget qui consomme `dashDataProvider` voit la nouvelle période
// automatiquement.
// ═════════════════════════════════════════════════════════════════════════════

enum PeriodSelectorMode { chips, inline }

class PeriodSelector extends ConsumerWidget {
  final PeriodSelectorMode mode;

  /// Pour `mode == inline` uniquement : icône affichée devant le label.
  final IconData? leadingIcon;

  const PeriodSelector({
    super.key,
    this.mode = PeriodSelectorMode.chips,
    this.leadingIcon,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final period = ref.watch(dashPeriodProvider);
    final custom = ref.watch(dashCustomRangeProvider);
    final l = context.l10n;

    if (mode == PeriodSelectorMode.inline) {
      return _InlineButton(
        label: _periodLabel(l, period, custom),
        leadingIcon: leadingIcon ?? Icons.calendar_today_rounded,
        onTap: () => _openPicker(context, ref),
      );
    }

    return _Chips(
      current: period,
      onChanged: (p) {
        if (p == DashPeriod.custom) {
          _openPicker(context, ref);
        } else {
          ref.read(dashPeriodProvider.notifier).state = p;
          ref.read(dashCustomRangeProvider.notifier).state = null;
        }
      },
      onCustom: () => _openPicker(context, ref),
    );
  }

  static void _openPicker(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _BottomSheet(ref: ref),
    );
  }

  static String _periodLabel(AppLocalizations l, DashPeriod p,
      DashRange? custom) {
    switch (p) {
      case DashPeriod.today:     return l.periodToday;
      case DashPeriod.yesterday: return l.periodYesterday;
      case DashPeriod.week:      return l.periodWeek;
      case DashPeriod.month:     return l.periodMonth;
      case DashPeriod.quarter:   return l.periodQuarter;
      case DashPeriod.year:      return l.periodYear;
      case DashPeriod.custom:
        if (custom == null) return l.periodCustom;
        String fmt(DateTime d) =>
            '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';
        return '${fmt(custom.from)} – ${fmt(custom.to)}';
    }
  }
}

// ─── Rangée de chips (today / yesterday / week / month / year / custom) ─────
class _Chips extends StatelessWidget {
  final DashPeriod current;
  final ValueChanged<DashPeriod> onChanged;
  final VoidCallback onCustom;
  const _Chips({required this.current, required this.onChanged,
      required this.onCustom});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final items = <(DashPeriod, String)>[
      (DashPeriod.today,     l.periodToday),
      (DashPeriod.yesterday, l.periodYesterday),
      (DashPeriod.week,      l.periodWeek),
      (DashPeriod.month,     l.periodMonth),
      (DashPeriod.year,      l.periodYear),
      (DashPeriod.custom,    l.periodCustom),
    ];

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: items.map((it) {
        final active = current == it.$1;
        return Padding(
          padding: const EdgeInsets.only(right: 8),
          child: GestureDetector(
            onTap: () => onChanged(it.$1),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: active ? AppColors.primary : Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                    color: active
                        ? AppColors.primary
                        : const Color(0xFFE5E7EB)),
              ),
              child: Text(it.$2,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: active
                          ? Colors.white
                          : const Color(0xFF6B7280))),
            ),
          ),
        );
      }).toList()),
    );
  }
}

// ─── Bouton inline (ex: header graphique) ───────────────────────────────────
class _InlineButton extends StatelessWidget {
  final String label;
  final IconData leadingIcon;
  final VoidCallback onTap;
  const _InlineButton({required this.label, required this.leadingIcon,
      required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.primary.withOpacity(0.08),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(leadingIcon, size: 12, color: AppColors.primary),
        const SizedBox(width: 6),
        Text(label,
            style: TextStyle(fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppColors.primary)),
        const SizedBox(width: 2),
        Icon(Icons.keyboard_arrow_down_rounded,
            size: 14, color: AppColors.primary),
      ]),
    ),
  );
}

// ─── Bottom sheet plein (chips + custom range) ──────────────────────────────
class _BottomSheet extends StatefulWidget {
  final WidgetRef ref;
  const _BottomSheet({required this.ref});
  @override
  State<_BottomSheet> createState() => _BottomSheetState();
}

class _BottomSheetState extends State<_BottomSheet> {
  bool _showCustom = false;
  late DateTime _from;
  late DateTime _to;

  @override
  void initState() {
    super.initState();
    final existing = widget.ref.read(dashCustomRangeProvider);
    _from = existing?.from ?? DateTime.now().subtract(const Duration(days: 7));
    _to   = existing?.to   ?? DateTime.now();
    _showCustom =
        widget.ref.read(dashPeriodProvider) == DashPeriod.custom;
  }

  void _apply(DashPeriod p) {
    widget.ref.read(dashPeriodProvider.notifier).state = p;
    widget.ref.read(dashCustomRangeProvider.notifier).state = null;
    Navigator.of(context).pop();
  }

  void _applyCustom() {
    widget.ref.read(dashPeriodProvider.notifier).state = DashPeriod.custom;
    widget.ref.read(dashCustomRangeProvider.notifier).state =
        DashRange(_from, _to);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final current = widget.ref.read(dashPeriodProvider);
    final periods = <(DashPeriod, String)>[
      (DashPeriod.today,     l.periodToday),
      (DashPeriod.yesterday, l.periodYesterday),
      (DashPeriod.week,      l.periodWeek),
      (DashPeriod.month,     l.periodMonth),
      (DashPeriod.year,      l.periodYear),
      (DashPeriod.custom,    l.periodCustom),
    ];

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(20, 16, 20,
          MediaQuery.of(context).viewInsets.bottom + 20),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 36, height: 4,
            decoration: BoxDecoration(color: const Color(0xFFE5E7EB),
                borderRadius: BorderRadius.circular(2))),
        const SizedBox(height: 16),
        Text(l.periodCustomTitle,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        const SizedBox(height: 16),
        Wrap(spacing: 8, runSpacing: 8, children: periods.map((p) {
          final active = current == p.$1;
          return GestureDetector(
            onTap: () {
              if (p.$1 == DashPeriod.custom) {
                setState(() => _showCustom = true);
              } else {
                _apply(p.$1);
              }
            },
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: active ? AppColors.primary : const Color(0xFFF3F4F6),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(p.$2,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                      color: active
                          ? Colors.white
                          : const Color(0xFF374151))),
            ),
          );
        }).toList()),
        if (_showCustom) ...[
          const SizedBox(height: 20),
          _DateRow(
            from: _from, to: _to,
            onFromChanged: (d) => setState(() => _from = d),
            onToChanged:   (d) => setState(() => _to   = d),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity, height: 42,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: _applyCustom,
              child: Text(l.periodApply,
                  style: const TextStyle(color: Colors.white,
                      fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ]),
    );
  }
}

// ─── Sélection d'une plage de dates (from / to) ─────────────────────────────
class _DateRow extends StatelessWidget {
  final DateTime from, to;
  final ValueChanged<DateTime> onFromChanged, onToChanged;
  const _DateRow({required this.from, required this.to,
      required this.onFromChanged, required this.onToChanged});

  Future<DateTime?> _pick(BuildContext context, DateTime initial) =>
      showDatePicker(
        context: context,
        initialDate: initial,
        firstDate: DateTime(2020),
        lastDate: DateTime.now().add(const Duration(days: 3650)),
      );

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Row(children: [
      Expanded(child: _DateBtn(label: l.periodFrom, date: from,
          onTap: () async {
            final d = await _pick(context, from);
            if (d != null) onFromChanged(d);
          })),
      const SizedBox(width: 12),
      Expanded(child: _DateBtn(label: l.periodTo, date: to,
          onTap: () async {
            final d = await _pick(context, to);
            if (d != null) onToChanged(d);
          })),
    ]);
  }
}

class _DateBtn extends StatelessWidget {
  final String label;
  final DateTime date;
  final VoidCallback onTap;
  const _DateBtn({required this.label, required this.date, required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(children: [
        Icon(Icons.calendar_today_outlined, size: 14, color: AppColors.primary),
        const SizedBox(width: 6),
        Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(
              fontSize: 9, color: Color(0xFF9CA3AF))),
          Text('${date.day}/${date.month}/${date.year}',
              style: const TextStyle(fontSize: 12,
                  fontWeight: FontWeight.w600, color: Color(0xFF0F172A))),
        ])),
      ]),
    ),
  );
}
