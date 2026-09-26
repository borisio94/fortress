part of 'staff_payroll_tab.dart';

// Les FEUILLES de l'onglet Paie. Chacune rend ce qui a été saisi, et c'est
// l'onglet qui décide quoi en faire (refus, écriture, message) — exactement
// comme avant l'extraction, où ces contrôles se faisaient déjà après la
// fermeture (cf. backlog « la saisie perdue sur un champ oublié »).
//
// Les feuilles à champs sont des widgets À ÉTAT, propriétaires de leurs
// contrôleurs : ils étaient créés dans les méthodes de l'onglet et jamais
// libérés. Extraites de `_PayrollTabState` le 26/09/2026 (lot « classes
// géantes »), sous le banc `test/widget/staff_payroll_tab_test.dart`.

/// Les trois mouvements d'argent possibles sur un employé, réunis derrière
/// un seul bouton : la quinzaine (un droit), l'avance (une faveur motivée)
/// et la casse (une dette). Trois icônes séparées sur chaque ligne auraient
/// rendu la liste illisible sur un téléphone.
///
/// Rend `'fortnight'`, `'advance'` ou `'penalty'`.
class _MoneyMenuSheet extends StatelessWidget {
  final StaffMember member;
  final DateTime month;

  /// Quinzaine déjà touchée ce mois, et son plafond.
  final int taken;
  final int cap;

  const _MoneyMenuSheet({
    required this.member,
    required this.month,
    required this.taken,
    required this.cap,
  });

  @override
  Widget build(BuildContext context) {
    return AdaptiveFormFrame(
      title: member.fullName,
      subtitle: _monthLabel(month),
      icon: Icons.account_balance_wallet_outlined,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.event_repeat_outlined),
            title: const Text('Verser la quinzaine'),
            subtitle: Text(cap <= 0
                ? 'Aucun salaire de base renseigné'
                : taken >= cap
                    ? 'Déjà touchée ce mois-ci '
                        '(${CurrencyFormatter.format(taken.toDouble())})'
                    : 'Jusqu\'à '
                        '${CurrencyFormatter.format((cap - taken).toDouble())}'
                        ', sans justification'),
            enabled: cap > 0 && taken < cap,
            onTap: () => Navigator.of(context).pop('fortnight'),
          ),
          ListTile(
            leading: const Icon(Icons.request_quote_outlined),
            title: const Text('Avance sur salaire'),
            subtitle: const Text('À tout moment, avec un motif'),
            onTap: () => Navigator.of(context).pop('advance'),
          ),
          ListTile(
            leading: const Icon(Icons.report_gmailerrorred_outlined),
            title: const Text('Imputer une casse'),
            subtitle: const Text('Un bien détruit par imprudence'),
            onTap: () => Navigator.of(context).pop('penalty'),
          ),
        ]),
      ),
    );
  }
}

/// Avance sur salaire : rend le montant (0 s'il ne se lit pas) et le motif
/// tel que saisi.
class _AdvanceSheet extends StatefulWidget {
  final StaffMember member;
  final DateTime month;

  const _AdvanceSheet({required this.member, required this.month});

  @override
  State<_AdvanceSheet> createState() => _AdvanceSheetState();
}

class _AdvanceSheetState extends State<_AdvanceSheet> {
  final _amount = TextEditingController();
  final _reason = TextEditingController();

  @override
  void dispose() {
    _amount.dispose();
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AdaptiveFormFrame(
      title: 'Avance sur salaire',
      subtitle: widget.member.fullName,
      icon: Icons.request_quote_outlined,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(
              'Elle sera retenue automatiquement sur la paie de '
              '${_monthLabel(widget.month)}. Contrairement à la quinzaine, une '
              'avance se motive.',
              style: AppTextStyles.captionHint),
          const SizedBox(height: 12),
          TextField(
            controller: _amount,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(),
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(labelText: 'Montant'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _reason,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
                labelText: 'Motif *',
                hintText: 'Frais de santé, transport…'),
          ),
          const SizedBox(height: 18),
          AppPrimaryButton(
            label: 'Enregistrer l\'avance',
            icon: Icons.check_rounded,
            fullWidth: true,
            onTap: () => Navigator.of(context).pop((
              amount: int.tryParse(_amount.text.trim()) ?? 0,
              reason: _reason.text,
            )),
          ),
        ]),
      ),
    );
  }
}

/// LA QUINZAINE — la moitié du salaire, sans avoir à se justifier.
///
/// Rend le montant saisi (0 s'il ne se lit pas). Le montant est pré-rempli au
/// reste du plafond ([left]) ; l'espèce en caisse ([cash]) s'affiche en
/// alerte quand elle ne le couvre pas.
class _FortnightSheet extends StatefulWidget {
  final StaffMember member;
  final DateTime month;
  final int cap;
  final int taken;
  final int left;
  final int cash;

  const _FortnightSheet({
    required this.member,
    required this.month,
    required this.cap,
    required this.taken,
    required this.left,
    required this.cash,
  });

  @override
  State<_FortnightSheet> createState() => _FortnightSheetState();
}

class _FortnightSheetState extends State<_FortnightSheet> {
  late final _amount = TextEditingController(text: '${widget.left}');

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return AdaptiveFormFrame(
      title: 'Quinzaine',
      subtitle: widget.member.fullName,
      icon: Icons.event_repeat_outlined,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
                'Aucun motif n\'est demandé : c\'est un droit. Elle sera '
                'retenue sur la paie de ${_monthLabel(widget.month)}.',
                style: AppTextStyles.captionHint),
            const SizedBox(height: 10),
            _kv('Salaire de base', widget.member.baseSalary),
            _kv('Plafond de la quinzaine', widget.cap),
            if (widget.taken > 0) _kv('Déjà touché ce mois', widget.taken),
            const Divider(height: 18),
            Row(children: [
              const Expanded(
                  child: Text('Espèces en caisse',
                      style: AppTextStyles.bodySm)),
              Text(CurrencyFormatter.format(widget.cash.toDouble()),
                  style: AppTextStyles.bodySmBold.copyWith(
                      color: widget.cash < widget.left
                          ? sem.warningText
                          : sem.successText)),
            ]),
            const SizedBox(height: 12),
            TextField(
              controller: _amount,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(),
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: 'Montant versé'),
            ),
            const SizedBox(height: 18),
            AppPrimaryButton(
              label: 'Verser',
              icon: Icons.check_rounded,
              fullWidth: true,
              onTap: () => Navigator.of(context)
                  .pop(int.tryParse(_amount.text.trim()) ?? 0),
            ),
          ],
        ),
      ),
    );
  }
}

/// Ce que la feuille de casse a saisi — textes TELS QUE TAPÉS : l'onglet les
/// contrôle rognés, mais les enregistre bruts, comme avant l'extraction.
typedef _PenaltyInput = ({
  String item,
  int amount,
  String reason,
  PenaltyMode mode,
  int percent,
});

/// CASSE IMPUTÉE — le montant du bien, et la façon de le récupérer.
class _PenaltySheet extends StatefulWidget {
  final StaffMember member;
  final String shopId;

  /// Mois de départ de la retenue (`YYYY-MM`), pour l'aperçu de l'étalement.
  final String monthKey;

  const _PenaltySheet({
    required this.member,
    required this.shopId,
    required this.monthKey,
  });

  @override
  State<_PenaltySheet> createState() => _PenaltySheetState();
}

class _PenaltySheetState extends State<_PenaltySheet> {
  final _item = TextEditingController();
  final _amount = TextEditingController();
  final _reason = TextEditingController();
  var _mode = PenaltyMode.oneShot;
  var _percent = 25;

  @override
  void dispose() {
    _item.dispose();
    _amount.dispose();
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final value = int.tryParse(_amount.text.trim()) ?? 0;
    final preview = StaffPenalty(
      id: '_', shopId: widget.shopId, employeeId: widget.member.id,
      itemLabel: '', amount: value, mode: _mode,
      percentPerMonth: _percent, startMonth: widget.monthKey, reason: '',
      incidentDate: DateTime.now(), createdAt: DateTime.now(),
    );
    return AdaptiveFormFrame(
      title: 'Imputer une casse',
      subtitle: widget.member.fullName,
      icon: Icons.report_gmailerrorred_outlined,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _item,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                  labelText: 'Bien détruit *',
                  hintText: 'Blender, vitre du frigo…'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(),
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                  labelText: 'Valeur du bien *'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _reason,
              maxLines: 2,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Circonstances *',
                hintText: 'A fait tomber le blender en le rinçant',
              ),
            ),
            const SizedBox(height: 14),
            const Text('Comment récupérer la somme ?',
                style: AppTextStyles.label),
            const SizedBox(height: 6),
            for (final m2 in PenaltyMode.values)
              RadioListTile<PenaltyMode>(
                value: m2,
                groupValue: _mode,
                onChanged: (v) => setState(() => _mode = v ?? _mode),
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(m2.label, style: AppTextStyles.bodySm),
              ),
            if (_mode == PenaltyMode.installments) ...[
              Row(children: [
                Expanded(
                  child: Text('$_percent % du montant par mois',
                      style: AppTextStyles.bodySm),
                ),
                Text(
                    value <= 0
                        ? ''
                        : '${preview.monthsNeeded} mois × '
                            '${CurrencyFormatter.format(preview.monthlyShare.toDouble())}',
                    style: AppTextStyles.caption),
              ]),
              Slider(
                value: _percent.toDouble(),
                min: 5,
                max: 100,
                divisions: 19,
                label: '$_percent %',
                onChanged: (v) => setState(() => _percent = v.round()),
              ),
            ],
            if (_mode == PenaltyMode.cashRepaid)
              Text(
                  'Le salaire ne sera JAMAIS touché. La casse reste '
                  'inscrite comme trace de l\'incident.',
                  style: AppTextStyles.captionHint),
            const SizedBox(height: 14),
            AppPrimaryButton(
              label: 'Enregistrer',
              icon: Icons.check_rounded,
              fullWidth: true,
              onTap: () => Navigator.of(context).pop<_PenaltyInput>((
                item: _item.text,
                amount: int.tryParse(_amount.text.trim()) ?? 0,
                reason: _reason.text,
                mode: _mode,
                percent: _percent,
              )),
            ),
          ],
        ),
      ),
    );
  }
}

/// Génération de la fiche du mois : les éléments automatiques, les primes et
/// retenues à saisir, et le net recalculé à chaque frappe.
///
/// Rend primes et retenues (0 si le champ ne se lit pas).
class _GenerateSheet extends StatefulWidget {
  final StaffMember member;
  final DateTime month;
  final int advances;
  final int minutes;
  final ({int minutes, int amount}) overtime;
  final int penalty;
  final ({int amount, int days}) absence;

  /// Départs anticipés non justifiés du mois — signalés, jamais retenus.
  final int unexcused;

  const _GenerateSheet({
    required this.member,
    required this.month,
    required this.advances,
    required this.minutes,
    required this.overtime,
    required this.penalty,
    required this.absence,
    required this.unexcused,
  });

  @override
  State<_GenerateSheet> createState() => _GenerateSheetState();
}

class _GenerateSheetState extends State<_GenerateSheet> {
  final _bonuses = TextEditingController();
  final _deductions = TextEditingController();

  @override
  void dispose() {
    _bonuses.dispose();
    _deductions.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.member;
    final advances = widget.advances;
    final minutes = widget.minutes;
    final overtime = widget.overtime;
    final penalty = widget.penalty;
    final absence = widget.absence;
    final unexcused = widget.unexcused;
    final net = Payslip.computeNet(
      baseSalary: m.baseSalary,
      bonuses: int.tryParse(_bonuses.text.trim()) ?? 0,
      deductions: int.tryParse(_deductions.text.trim()) ?? 0,
      advances: advances,
      overtime: overtime.amount,
      penalties: penalty,
      absences: absence.amount,
    );
    return AdaptiveFormFrame(
      title: 'Paie ${_monthLabel(widget.month)}',
      subtitle: m.fullName,
      icon: Icons.payments_outlined,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _kv('Salaire de base', m.baseSalary),
            if (minutes > 0)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  Expanded(
                      child: Text('Heures pointées',
                          style: AppTextStyles.captionHint)),
                  Text(TimeRecord.formatMinutes(minutes),
                      style: AppTextStyles.caption),
                ]),
              ),
            if (overtime.amount > 0)
              _kv(
                  'Heures supplémentaires '
                  '(${TimeRecord.formatMinutes(overtime.minutes)})',
                  overtime.amount),
            if (penalty > 0) _kv('Casse imputée', -penalty),
            if (absence.amount > 0)
              _kv(
                  'Mise à pied (${absence.days} jour'
                  '${absence.days > 1 ? 's' : ''})',
                  -absence.amount),
            if (advances > 0) _kv('Avances et quinzaines', -advances),
            if (unexcused > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(children: [
                  Icon(Icons.info_outline_rounded,
                      size: 14,
                      color: Theme.of(context).semantic.warning),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                        '$unexcused départ${unexcused > 1 ? 's' : ''} '
                        'anticipé${unexcused > 1 ? 's' : ''} non '
                        'justifié${unexcused > 1 ? 's' : ''} ce mois-ci. '
                        'À vous de décider d\'une retenue.',
                        style: AppTextStyles.micro.copyWith(
                            color: Theme.of(context).semantic.warningText)),
                  ),
                ]),
              ),
            const SizedBox(height: 10),
            TextField(
              controller: _bonuses,
              keyboardType: const TextInputType.numberWithOptions(),
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Primes / heures supplémentaires',
                hintText: '0',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _deductions,
              keyboardType: const TextInputType.numberWithOptions(),
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Retenues (retards, casse…)',
                hintText: '0',
              ),
            ),
            const SizedBox(height: 10),
            _kv('Avances déjà versées', -advances),
            const Divider(height: 20),
            Row(children: [
              const Expanded(
                  child: Text('Net à payer',
                      style: AppTextStyles.bodyBold)),
              Text(CurrencyFormatter.format(net.toDouble()),
                  style: AppTextStyles.subtitleBold),
            ]),
            const SizedBox(height: 18),
            AppPrimaryButton(
              label: 'Générer la fiche',
              icon: Icons.check_rounded,
              fullWidth: true,
              onTap: () => Navigator.of(context).pop((
                bonuses: int.tryParse(_bonuses.text.trim()) ?? 0,
                deductions: int.tryParse(_deductions.text.trim()) ?? 0,
              )),
            ),
          ],
        ),
      ),
    );
  }
}

/// Une fiche de paie générée : son détail, « Marquer comme payée » et
/// « Supprimer la fiche ». Rend `'paid'` ou `'delete'`.
class _SlipSheet extends StatelessWidget {
  final StaffMember member;
  final Payslip slip;
  final DateTime month;

  const _SlipSheet({
    required this.member,
    required this.slip,
    required this.month,
  });

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return AdaptiveFormFrame(
      title: 'Fiche ${_monthLabel(month)}',
      subtitle: member.fullName,
      icon: Icons.receipt_long_outlined,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _kv('Salaire de base', slip.baseSalary),
            if (slip.bonuses > 0) _kv('Primes', slip.bonuses),
            // Les heures supplémentaires portent leur MENTION : sans le
            // nombre d'heures à côté du montant, la ligne est invérifiable —
            // et c'est la première que l'employé conteste.
            if (slip.overtimeAmount > 0)
              _kv(
                  'Heures supplémentaires '
                  '(${TimeRecord.formatMinutes(slip.overtimeMinutes)})',
                  slip.overtimeAmount),
            if (slip.deductions > 0) _kv('Retenues', -slip.deductions),
            if (slip.penaltiesDeducted > 0)
              _kv('Casse imputée', -slip.penaltiesDeducted),
            if (slip.absencesDeducted > 0)
              _kv(
                  'Mise à pied (${slip.absenceDays} jour'
                  '${slip.absenceDays > 1 ? 's' : ''})',
                  -slip.absencesDeducted),
            if (slip.advancesDeducted > 0)
              _kv('Avances et quinzaines', -slip.advancesDeducted),
            if (slip.minutesWorked > 0)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  Expanded(
                      child: Text('Heures pointées',
                          style: AppTextStyles.captionHint)),
                  Text(TimeRecord.formatMinutes(slip.minutesWorked),
                      style: AppTextStyles.caption),
                ]),
              ),
            const Divider(height: 20),
            Row(children: [
              const Expanded(
                  child:
                      Text('Net à payer', style: AppTextStyles.bodyBold)),
              Text(CurrencyFormatter.format(slip.netSalary.toDouble()),
                  style: AppTextStyles.subtitleBold),
            ]),
            const SizedBox(height: 18),
            if (!slip.isPaid)
              AppPrimaryButton(
                label: 'Marquer comme payée',
                icon: Icons.check_rounded,
                fullWidth: true,
                onTap: () => Navigator.of(context).pop('paid'),
              )
            else
              Center(
                child: Text('Payée le ${_dayLabel(slip.paidAt!)}',
                    style: AppTextStyles.caption),
              ),
            const SizedBox(height: 6),
            Center(
              child: TextButton.icon(
                onPressed: () => Navigator.of(context).pop('delete'),
                icon: Icon(Icons.delete_outline_rounded,
                    size: 18, color: sem.danger),
                label: Text('Supprimer la fiche',
                    style:
                        AppTextStyles.label.copyWith(color: sem.dangerText)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Une mise à pied ou un congé : dates, motif, effet sur la paie, et les deux
/// gestes possibles. Rend `'lift'` ou `'delete'`.
class _AbsenceSheet extends StatelessWidget {
  final StaffAbsence absence;

  const _AbsenceSheet({required this.absence});

  @override
  Widget build(BuildContext context) {
    final a = absence;
    final sem = Theme.of(context).semantic;
    return AdaptiveFormFrame(
      title: a.kind.label,
      subtitle: a.employeeName ?? 'Employé',
      icon: a.kind == AbsenceKind.suspension
          ? Icons.gavel_rounded
          : Icons.beach_access_rounded,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('${_dayLabel(a.startDate)} → ${_dayLabel(a.endDate)} · '
                '${a.days} jour${a.days > 1 ? 's' : ''}',
                style: AppTextStyles.bodySm),
            const SizedBox(height: 6),
            Text('« ${a.reason} »', style: AppTextStyles.bodySm),
            const SizedBox(height: 6),
            Text(
                a.isCancelled
                    ? 'Levée le ${_dayLabel(a.cancelledAt!)}'
                    : a.hitsPayroll
                        ? a.amountDeducted > 0
                            ? 'Déjà retenu : '
                                '${CurrencyFormatter.format(a.amountDeducted.toDouble())}'
                            : 'Sans solde — la retenue sera portée sur la '
                                'prochaine fiche de paie.'
                        : 'Salaire maintenu, rien n\'est retenu.',
                style: AppTextStyles.caption),
            const SizedBox(height: 16),
            if (!a.isCancelled)
              AppPrimaryButton(
                label: 'Lever cette décision',
                icon: Icons.undo_rounded,
                fullWidth: true,
                onTap: () => Navigator.of(context).pop('lift'),
              ),
            const SizedBox(height: 6),
            Center(
              child: TextButton.icon(
                onPressed: () => Navigator.of(context).pop('delete'),
                icon: Icon(Icons.delete_outline_rounded,
                    size: 18, color: sem.danger),
                label: Text('Supprimer la ligne',
                    style:
                        AppTextStyles.label.copyWith(color: sem.dangerText)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
