part of 'staff_payroll_tab.dart';

// Les LISTES de l'onglet Paie : la ligne d'un employé, puis les avances, les
// casses et les absences. Des widgets sans état, qui reçoivent leurs données
// et rendent la main par des rappels. Extraites de `_PayrollTabState` le
// 26/09/2026 (lot « classes géantes »), sous le banc
// `test/widget/staff_payroll_tab_test.dart`.

/// Une colonne étirée : les cartes y prennent toute la largeur, comme
/// lorsqu'elles étaient posées une à une dans la liste de l'onglet.
Widget _column(List<Widget> children) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );

/// Les avances du mois affiché, versées à qui et retenues ou non.
///
/// Une avance déjà retenue reste visible (en vert) : c'est la trace de ce
/// qui a été déduit sur la fiche, et la première chose qu'un employé
/// conteste.
class _AdvancesList extends StatelessWidget {
  final List<SalaryAdvance> list;
  final ValueChanged<SalaryAdvance> onTap;

  const _AdvancesList({required this.list, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    if (list.isEmpty) {
      return _column([
        const RestoEmptyNote('Aucune avance versée sur ce mois.'),
      ]);
    }
    return _column([
      for (final a in list)
        RestoListCard(
          onTap: () => onTap(a),
          child: Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(a.employeeName ?? 'Employé',
                      style: AppTextStyles.bodySmBold),
                  Text(
                      [
                        _dayLabel(a.advanceDate),
                        if (a.isFortnight) 'quinzaine',
                        if ((a.reason ?? '').isNotEmpty) a.reason!,
                        if (a.isDeducted) 'retenue',
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.caption),
                ],
              ),
            ),
            Text(CurrencyFormatter.format(a.amount.toDouble()),
                style: AppTextStyles.bodySmBold.copyWith(
                    color: a.isDeducted ? sem.successText : sem.warningText)),
          ]),
        ),
    ]);
  }
}

/// Les casses en cours de récupération, et celles déjà soldées du mois.
class _PenaltiesList extends StatelessWidget {
  final List<StaffPenalty> list;
  final ValueChanged<StaffPenalty> onTap;

  const _PenaltiesList({required this.list, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    if (list.isEmpty) {
      return _column([
        const RestoEmptyNote('Aucune casse imputée.'),
      ]);
    }
    return _column([
      for (final p in list)
        RestoListCard(
          onTap: () => onTap(p),
          child: Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${p.employeeName ?? 'Employé'} · ${p.itemLabel}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.bodySmBold),
                  Text(
                      [
                        _dayLabel(p.incidentDate),
                        p.mode.label,
                        if (p.isSettled)
                          'soldée'
                        else
                          'reste ${CurrencyFormatter.format(p.remaining.toDouble())}',
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.caption),
                ],
              ),
            ),
            Text(CurrencyFormatter.format(p.amount.toDouble()),
                style: AppTextStyles.bodySmBold.copyWith(
                    color: p.isSettled ? sem.successText : sem.warningText)),
          ]),
        ),
    ]);
  }
}

/// Les mises à pied et congés, la plus récente en tête.
///
/// Les LEVÉES restent affichées, barrées d'un libellé : « la mise à pied a
/// été levée » est une information, la faire disparaître laisserait croire
/// qu'elle n'a jamais eu lieu.
class _AbsencesList extends StatelessWidget {
  final List<StaffAbsence> list;
  final ValueChanged<StaffAbsence> onTap;

  const _AbsencesList({required this.list, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    if (list.isEmpty) {
      return _column([
        const RestoEmptyNote('Aucune mise à pied ni congé enregistré.'),
      ]);
    }
    return _column([
      for (final a in list.take(20))
        RestoListCard(
          onTap: () => onTap(a),
          child: Row(children: [
            Icon(
                a.kind == AbsenceKind.suspension
                    ? Icons.gavel_rounded
                    : Icons.beach_access_rounded,
                size: 16,
                color: a.isCancelled
                    ? Theme.of(context).colorScheme.onSurface
                        .withValues(alpha: 0.35)
                    : (a.hitsPayroll ? sem.warning : sem.success)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${a.employeeName ?? 'Employé'} · ${a.kind.label}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.bodySmBold),
                  Text(
                      [
                        '${_dayLabel(a.startDate)} → ${_dayLabel(a.endDate)}',
                        '${a.days} j',
                        if (a.isCancelled)
                          'levée'
                        else if (a.isPaid)
                          'payée'
                        else
                          'sans solde',
                        a.reason,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.caption),
                ],
              ),
            ),
            if (a.amountDeducted > 0)
              Text('−${CurrencyFormatter.format(a.amountDeducted.toDouble())}',
                  style:
                      AppTextStyles.bodySmBold.copyWith(color: sem.warningText)),
          ]),
        ),
    ]);
  }
}

/// Une ligne d'employé dans l'onglet Paie.
class _PayrollRow extends StatelessWidget {
  final StaffMember member;
  final String month;
  final Payslip? slip;
  final int pendingAdvances;
  final int minutes;

  /// Heures supplémentaires reportées sur la paie de ce mois, pas encore
  /// portées sur une fiche.
  final ({int minutes, int amount}) overtime;

  /// Retenue pour casse due ce mois.
  final int penalty;

  /// Retenue pour mise à pied sans solde due ce mois.
  final int absence;

  final VoidCallback onGenerate;
  final ValueChanged<Payslip> onOpen;
  final VoidCallback onMoney;

  const _PayrollRow({
    required this.member,
    required this.month,
    required this.slip,
    required this.pendingAdvances,
    required this.minutes,
    required this.overtime,
    required this.penalty,
    required this.absence,
    required this.onGenerate,
    required this.onOpen,
    required this.onMoney,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    final s = slip;
    return RestoListCard(
      onTap: () => s == null ? onGenerate() : onOpen(s),
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(member.fullName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.bodyBold.copyWith(color: cs.onSurface)),
              Text(
                  [
                    CurrencyFormatter.format(member.baseSalary.toDouble()),
                    if (minutes > 0) TimeRecord.formatMinutes(minutes),
                    if (pendingAdvances > 0)
                      'avances ${CurrencyFormatter.format(pendingAdvances.toDouble())}',
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.caption),
              // Ce qui s'ajoutera ou se retirera automatiquement à la
              // génération : le gérant doit le voir AVANT de générer, pas le
              // découvrir sur la fiche.
              if (overtime.amount > 0 || penalty > 0 || absence > 0)
                Text(
                    [
                      if (overtime.amount > 0)
                        '+${CurrencyFormatter.format(overtime.amount.toDouble())} '
                            'heures sup',
                      if (penalty > 0)
                        '−${CurrencyFormatter.format(penalty.toDouble())} casse',
                      if (absence > 0)
                        '−${CurrencyFormatter.format(absence.toDouble())} '
                            'mise à pied',
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.micro.copyWith(
                        color: (penalty > 0 || absence > 0)
                            ? sem.warningText
                            : sem.successText)),
            ],
          ),
        ),
        IconButton(
          onPressed: onMoney,
          icon: const Icon(Icons.account_balance_wallet_outlined, size: 20),
          tooltip: 'Quinzaine, avance, casse',
        ),
        if (s == null)
          Text('à générer',
              style: AppTextStyles.caption.copyWith(color: sem.warningText))
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(CurrencyFormatter.format(s.netSalary.toDouble()),
                  style: AppTextStyles.bodySmBold),
              Text(s.isPaid ? 'payée' : 'à payer',
                  style: AppTextStyles.micro.copyWith(
                      color: s.isPaid ? sem.successText : sem.warningText)),
            ],
          ),
      ]),
    );
  }
}
