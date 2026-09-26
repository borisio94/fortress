import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;

import '../../../../core/services/cash_closure_service.dart';
import '../../../../core/services/staff_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_confirm_dialog.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../domain/entities/payslip.dart';
import '../../domain/entities/salary_advance.dart';
import '../../domain/entities/staff_absence.dart';
import '../../domain/entities/staff_member.dart';
import '../../domain/entities/staff_penalty.dart';
import '../../domain/entities/time_record.dart';
import 'resto_empty_state.dart';
import 'resto_surfaces.dart';
import 'resto_table_listener.dart';

// L'onglet PAIE de la page Personnel.
//
// Sorti de `restaurant_staff_page.dart` (où il était un `part`) le 26/09/2026,
// lot « classes géantes » : une classe privée d'une page sous `AppScaffold` ne
// se monte pas en test. Public et dans son fichier, comme Notation
// (`StaffRatingTab`) et Primes (`StaffContestTab`), il reçoit un banc de test
// avant qu'on découpe sa classe d'état.

// ═══════════════════════════════════════════════════════════════════════
//  Onglet PAIE
// ═══════════════════════════════════════════════════════════════════════
class StaffPayrollTab extends StatefulWidget {
  final String shopId;
  const StaffPayrollTab({super.key, required this.shopId});
  @override
  State<StaffPayrollTab> createState() => _PayrollTabState();
}

class _PayrollTabState extends RestoTableListenerState<StaffPayrollTab> {
  @override
  List<String> get tables => const [
        'payroll', 'salary_advances', 'employees', 'time_records',
        'staff_penalties', 'staff_absences',
      ];
  @override
  String get shopId => widget.shopId;

  late DateTime _month = DateTime.now();

  String get _monthKey => SalaryAdvance.monthKey(_month);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    final members = StaffService.forShop(widget.shopId, onlyActive: true);
    final slips = StaffService.payslips(widget.shopId, month: _monthKey);
    final total = slips.fold<int>(0, (s, p) => s + p.netSalary);

    return Column(
      children: [
        // Sélecteur de mois : la paie se prépare souvent le mois suivant.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: [
              IconButton(
                onPressed: () => setState(() =>
                    _month = DateTime(_month.year, _month.month - 1)),
                icon: const Icon(Icons.chevron_left_rounded),
              ),
              Expanded(
                child: Text(_monthLabel(_month),
                    textAlign: TextAlign.center,
                    style: AppTextStyles.bodyBold),
              ),
              IconButton(
                onPressed: () => setState(() =>
                    _month = DateTime(_month.year, _month.month + 1)),
                icon: const Icon(Icons.chevron_right_rounded),
              ),
            ],
          ),
        ),
        if (slips.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Expanded(
                    child: Text('${slips.length} fiche'
                        '${slips.length > 1 ? 's' : ''} générée'
                        '${slips.length > 1 ? 's' : ''}',
                        style: AppTextStyles.caption)),
                Text(CurrencyFormatter.format(total.toDouble()),
                    style: AppTextStyles.bodyBold.copyWith(color: cs.onSurface)),
              ],
            ),
          ),
        Expanded(
          child: members.isEmpty
              ? const RestoEmptyState(
                  icon: Icons.payments_outlined,
                  title: 'Aucun employé',
                  subtitle: 'Ajoutez votre équipe pour préparer la paie.',
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  children: [
                    for (final m in members)
                      _PayrollRow(
                        member: m,
                        month: _monthKey,
                        slip: StaffService.payslipFor(
                            widget.shopId, m.id, _monthKey),
                        pendingAdvances: StaffService.pendingAdvances(
                            widget.shopId, m.id, _monthKey),
                        minutes: StaffService.minutesInMonth(
                            widget.shopId, m.id, _monthKey),
                        overtime: StaffService.pendingOvertime(
                            widget.shopId, m.id, _monthKey),
                        penalty: StaffService.penaltyDueFor(
                            widget.shopId, m.id, _monthKey),
                        absence:
                            StaffService.absenceDueFor(m, _monthKey).amount,
                        onGenerate: () => _generate(m),
                        onOpen: (slip) => _openSlip(m, slip),
                        onMoney: () => _moneyActions(m),
                      ),
                    const SizedBox(height: 12),
                    const Text('Avances et quinzaines',
                        style: AppTextStyles.bodyBold),
                    const SizedBox(height: 6),
                    ..._advancesSection(sem),
                    const SizedBox(height: 16),
                    const Text('Casse imputée', style: AppTextStyles.bodyBold),
                    const SizedBox(height: 6),
                    ..._penaltiesSection(sem),
                    const SizedBox(height: 16),
                    const Text('Mises à pied et congés',
                        style: AppTextStyles.bodyBold),
                    const SizedBox(height: 6),
                    ..._absencesSection(sem),
                  ],
                ),
        ),
      ],
    );
  }

  /// Les avances du mois affiché, versées à qui et retenues ou non.
  ///
  /// Une avance déjà retenue reste visible (en vert) : c'est la trace de ce
  /// qui a été déduit sur la fiche, et la première chose qu'un employé
  /// conteste.
  List<Widget> _advancesSection(AppSemanticColors sem) {
    final list = StaffService.advances(widget.shopId, month: _monthKey);
    if (list.isEmpty) {
      return [
        const RestoEmptyNote('Aucune avance versée sur ce mois.'),
      ];
    }
    return [
      for (final a in list)
        RestoListCard(
          onTap: () => _advanceActions(a),
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
    ];
  }

  Future<void> _addAdvance(StaffMember m) async {
    final amount = TextEditingController();
    final reason = TextEditingController();
    final value = await showAdaptiveFormSheet<int>(
      context: context,
      builder: (sheetCtx) => AdaptiveFormFrame(
        title: 'Avance sur salaire',
        subtitle: m.fullName,
        icon: Icons.request_quote_outlined,
        body: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(
                'Elle sera retenue automatiquement sur la paie de '
                '${_monthLabel(_month)}. Contrairement à la quinzaine, une '
                'avance se motive.',
                style: AppTextStyles.captionHint),
            const SizedBox(height: 12),
            TextField(
              controller: amount,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(),
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: 'Montant'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: reason,
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
              onTap: () => Navigator.of(sheetCtx)
                  .pop(int.tryParse(amount.text.trim()) ?? 0),
            ),
          ]),
        ),
      ),
    );
    if (value == null || value <= 0 || !mounted) return;
    // Le motif est exigé ici et NULLE PART pour la quinzaine : c'est toute la
    // différence entre une faveur et un droit. Sans lui, plus rien ne
    // distingue les deux au moment de relire le mois.
    if (reason.text.trim().isEmpty) {
      AppSnack.info(context,
          'Indiquez le motif de l\'avance. Sans motif, versez plutôt la '
          'quinzaine.');
      return;
    }
    await StaffService.recordAdvance(
      member: m,
      amount: value,
      reason: reason.text.trim(),
      month: _monthKey,
    );
    if (!mounted) return;
    setState(() {});
    AppSnack.success(context, 'Avance enregistrée.');
  }

  /// Les trois mouvements d'argent possibles sur un employé, réunis derrière
  /// un seul bouton : la quinzaine (un droit), l'avance (une faveur motivée)
  /// et la casse (une dette). Trois icônes séparées sur chaque ligne auraient
  /// rendu la liste illisible sur un téléphone.
  Future<void> _moneyActions(StaffMember m) async {
    final taken =
        StaffService.fortnightTaken(widget.shopId, m.id, _monthKey);
    final cap = SalaryAdvance.fortnightCap(m.baseSalary);
    final action = await showAdaptiveFormSheet<String>(
      context: context,
      builder: (sheetCtx) => AdaptiveFormFrame(
        title: m.fullName,
        subtitle: _monthLabel(_month),
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
              onTap: () => Navigator.of(sheetCtx).pop('fortnight'),
            ),
            ListTile(
              leading: const Icon(Icons.request_quote_outlined),
              title: const Text('Avance sur salaire'),
              subtitle: const Text('À tout moment, avec un motif'),
              onTap: () => Navigator.of(sheetCtx).pop('advance'),
            ),
            ListTile(
              leading: const Icon(Icons.report_gmailerrorred_outlined),
              title: const Text('Imputer une casse'),
              subtitle: const Text('Un bien détruit par imprudence'),
              onTap: () => Navigator.of(sheetCtx).pop('penalty'),
            ),
          ]),
        ),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'fortnight':
        await _addFortnight(m);
        return;
      case 'advance':
        await _addAdvance(m);
        return;
      case 'penalty':
        await _addPenalty(m);
        return;
    }
  }

  /// LA QUINZAINE — la moitié du salaire, sans avoir à se justifier.
  ///
  /// Le seul contrôle est celui du FONDS : l'espèce réellement disponible dans
  /// le tiroir. Verser une quinzaine que la caisse ne contient pas, c'est
  /// découvrir le trou le soir à la clôture, quand il est trop tard pour
  /// arbitrer entre l'employé et le fournisseur.
  Future<void> _addFortnight(StaffMember m) async {
    final taken =
        StaffService.fortnightTaken(widget.shopId, m.id, _monthKey);
    final cap = SalaryAdvance.fortnightCap(m.baseSalary);
    final left = cap - taken;
    final cash = CashClosureService.systemCash(widget.shopId);
    final amount = TextEditingController(text: '$left');

    final confirmed = await showAdaptiveFormSheet<bool>(
      context: context,
      builder: (sheetCtx) => AdaptiveFormFrame(
        title: 'Quinzaine',
        subtitle: m.fullName,
        icon: Icons.event_repeat_outlined,
        body: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                  'Aucun motif n\'est demandé : c\'est un droit. Elle sera '
                  'retenue sur la paie de ${_monthLabel(_month)}.',
                  style: AppTextStyles.captionHint),
              const SizedBox(height: 10),
              _kv('Salaire de base', m.baseSalary),
              _kv('Plafond de la quinzaine', cap),
              if (taken > 0) _kv('Déjà touché ce mois', taken),
              const Divider(height: 18),
              Row(children: [
                const Expanded(
                    child: Text('Espèces en caisse',
                        style: AppTextStyles.bodySm)),
                Text(CurrencyFormatter.format(cash.toDouble()),
                    style: AppTextStyles.bodySmBold.copyWith(
                        color: cash < left
                            ? Theme.of(sheetCtx).semantic.warningText
                            : Theme.of(sheetCtx).semantic.successText)),
              ]),
              const SizedBox(height: 12),
              TextField(
                controller: amount,
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
                onTap: () => Navigator.of(sheetCtx).pop(true),
              ),
            ],
          ),
        ),
      ),
    );
    if (confirmed != true || !mounted) return;

    final value = int.tryParse(amount.text.trim()) ?? 0;
    if (value <= 0) return;
    if (value > left) {
      AppSnack.info(
          context,
          'Au-delà de '
          '${CurrencyFormatter.format(left.toDouble())}, ce n\'est plus une '
          'quinzaine : passez par une avance sur salaire.');
      return;
    }
    if (value > cash) {
      AppSnack.info(
          context,
          'La caisse ne contient que '
          '${CurrencyFormatter.format(cash.toDouble())}. '
          'Réapprovisionnez-la, ou versez une avance plus petite.');
      return;
    }
    await StaffService.recordFortnight(
        member: m, amount: value, month: _monthKey);
    if (!mounted) return;
    setState(() {});
    AppSnack.success(context, 'Quinzaine versée.');
  }

  /// CASSE IMPUTÉE — le montant du bien, et la façon de le récupérer.
  Future<void> _addPenalty(StaffMember m) async {
    final item = TextEditingController();
    final amount = TextEditingController();
    final reason = TextEditingController();
    var mode = PenaltyMode.oneShot;
    var percent = 25;

    final confirmed = await showAdaptiveFormSheet<bool>(
      context: context,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final value = int.tryParse(amount.text.trim()) ?? 0;
          final preview = StaffPenalty(
            id: '_', shopId: widget.shopId, employeeId: m.id,
            itemLabel: '', amount: value, mode: mode,
            percentPerMonth: percent, startMonth: _monthKey, reason: '',
            incidentDate: DateTime.now(), createdAt: DateTime.now(),
          );
          return AdaptiveFormFrame(
            title: 'Imputer une casse',
            subtitle: m.fullName,
            icon: Icons.report_gmailerrorred_outlined,
            body: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: item,
                    autofocus: true,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                        labelText: 'Bien détruit *',
                        hintText: 'Blender, vitre du frigo…'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: amount,
                    keyboardType: const TextInputType.numberWithOptions(),
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onChanged: (_) => setSheet(() {}),
                    decoration: const InputDecoration(
                        labelText: 'Valeur du bien *'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: reason,
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
                      groupValue: mode,
                      onChanged: (v) => setSheet(() => mode = v ?? mode),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(m2.label, style: AppTextStyles.bodySm),
                    ),
                  if (mode == PenaltyMode.installments) ...[
                    Row(children: [
                      Expanded(
                        child: Text('$percent % du montant par mois',
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
                      value: percent.toDouble(),
                      min: 5,
                      max: 100,
                      divisions: 19,
                      label: '$percent %',
                      onChanged: (v) => setSheet(() => percent = v.round()),
                    ),
                  ],
                  if (mode == PenaltyMode.cashRepaid)
                    Text(
                        'Le salaire ne sera JAMAIS touché. La casse reste '
                        'inscrite comme trace de l\'incident.',
                        style: AppTextStyles.captionHint),
                  const SizedBox(height: 14),
                  AppPrimaryButton(
                    label: 'Enregistrer',
                    icon: Icons.check_rounded,
                    fullWidth: true,
                    onTap: () => Navigator.of(sheetCtx).pop(true),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (confirmed != true || !mounted) return;

    final value = int.tryParse(amount.text.trim()) ?? 0;
    if (item.text.trim().isEmpty || value <= 0) {
      AppSnack.info(context, 'Indiquez le bien et sa valeur.');
      return;
    }
    if (reason.text.trim().isEmpty) {
      AppSnack.info(
          context,
          'Les circonstances sont obligatoires : sans elles, la retenue est '
          'indéfendable le jour où elle est contestée.');
      return;
    }
    await StaffService.recordPenalty(
      member: m,
      itemLabel: item.text,
      amount: value,
      reason: reason.text,
      mode: mode,
      percentPerMonth: percent,
      startMonth: _monthKey,
    );
    if (!mounted) return;
    setState(() {});
    AppSnack.success(
        context,
        mode == PenaltyMode.cashRepaid
            ? 'Casse enregistrée — salaire non impacté.'
            : 'Casse enregistrée, retenue à la prochaine paie.');
  }

  /// Les casses en cours de récupération, et celles déjà soldées du mois.
  List<Widget> _penaltiesSection(AppSemanticColors sem) {
    final list = StaffService.penalties(widget.shopId);
    if (list.isEmpty) {
      return [
        const RestoEmptyNote('Aucune casse imputée.'),
      ];
    }
    return [
      for (final p in list)
        RestoListCard(
          onTap: () => _penaltyActions(p),
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
    ];
  }

  /// Les mises à pied et congés, la plus récente en tête.
  ///
  /// Les LEVÉES restent affichées, barrées d'un libellé : « la mise à pied a
  /// été levée » est une information, la faire disparaître laisserait croire
  /// qu'elle n'a jamais eu lieu.
  List<Widget> _absencesSection(AppSemanticColors sem) {
    final list = StaffService.absences(widget.shopId);
    if (list.isEmpty) {
      return [
        const RestoEmptyNote('Aucune mise à pied ni congé enregistré.'),
      ];
    }
    return [
      for (final a in list.take(20))
        RestoListCard(
          onTap: () => _absenceActions(a),
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
    ];
  }

  Future<void> _absenceActions(StaffAbsence a) async {
    final action = await showAdaptiveFormSheet<String>(
      context: context,
      builder: (sheetCtx) => AdaptiveFormFrame(
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
                  onTap: () => Navigator.of(sheetCtx).pop('lift'),
                ),
              const SizedBox(height: 6),
              Center(
                child: TextButton.icon(
                  onPressed: () => Navigator.of(sheetCtx).pop('delete'),
                  icon: Icon(Icons.delete_outline_rounded,
                      size: 18, color: Theme.of(sheetCtx).semantic.danger),
                  label: Text('Supprimer la ligne',
                      style: AppTextStyles.label.copyWith(
                          color: Theme.of(sheetCtx).semantic.dangerText)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (action == null || !mounted) return;
    if (action == 'lift') {
      await StaffService.cancelAbsence(a);
      if (!mounted) return;
      setState(() {});
      AppSnack.success(context, 'Décision levée.');
      return;
    }
    final ok = await AppConfirmDialog.show(
      context: context,
      icon: Icons.delete_outline_rounded,
      iconColor: Theme.of(context).semantic.danger,
      title: 'Supprimer cette ligne ?',
      body: Text(a.amountDeducted > 0
          ? 'Une retenue de '
              '${CurrencyFormatter.format(a.amountDeducted.toDouble())} a déjà '
              'été portée sur une fiche de paie. Elle ne sera PAS rendue.'
          : 'La décision disparaît de l\'historique.'),
      cancelLabel: 'Annuler',
      confirmLabel: 'Supprimer',
      onConfirm: () {},
    );
    if (ok != true || !mounted) return;
    await StaffService.deleteAbsence(a);
    if (mounted) setState(() {});
  }

  Future<void> _penaltyActions(StaffPenalty p) async {
    final ok = await AppConfirmDialog.show(
      context: context,
      icon: Icons.delete_outline_rounded,
      iconColor: Theme.of(context).semantic.danger,
      title: 'Supprimer cette imputation ?',
      body: Text(
          '${p.itemLabel} · ${CurrencyFormatter.format(p.amount.toDouble())}\n'
          '${p.reason}\n\n'
          '${p.amountRecovered > 0 ? 'Déjà récupéré : '
              '${CurrencyFormatter.format(p.amountRecovered.toDouble())}. '
              'Ce montant ne sera PAS rendu automatiquement.' : ''}'),
      cancelLabel: 'Annuler',
      confirmLabel: 'Supprimer',
      onConfirm: () {},
    );
    if (ok != true || !mounted) return;
    await StaffService.deletePenalty(p);
    if (mounted) setState(() {});
  }

  Future<void> _advanceActions(SalaryAdvance a) async {
    if (a.isDeducted) {
      AppSnack.info(
          context,
          'Cette avance a déjà été retenue sur une fiche de paie. '
          'Supprimez la fiche pour la libérer.');
      return;
    }
    final ok = await AppConfirmDialog.show(
      context: context,
      icon: Icons.delete_outline_rounded,
      iconColor: Theme.of(context).semantic.danger,
      title: 'Supprimer cette avance ?',
      body: Text('${a.employeeName ?? 'Employé'} · '
          '${CurrencyFormatter.format(a.amount.toDouble())}'),
      cancelLabel: 'Annuler',
      confirmLabel: 'Supprimer',
      onConfirm: () {},
    );
    if (ok != true || !mounted) return;
    await StaffService.deleteAdvance(a);
    if (mounted) setState(() {});
  }

  Future<void> _generate(StaffMember m) async {
    final bonuses = TextEditingController();
    final deductions = TextEditingController();
    final advances =
        StaffService.pendingAdvances(widget.shopId, m.id, _monthKey);
    final minutes =
        StaffService.minutesInMonth(widget.shopId, m.id, _monthKey);
    final overtime =
        StaffService.pendingOvertime(widget.shopId, m.id, _monthKey);
    final penalty =
        StaffService.penaltyDueFor(widget.shopId, m.id, _monthKey);
    final absence = StaffService.absenceDueFor(m, _monthKey);
    // Départs anticipés non justifiés du mois : SIGNALÉS, jamais retenus. Le
    // gérant en fait ce qu'il veut dans le champ « retenues » — c'est lui qui
    // connaît le contexte, pas l'application.
    final unexcused = StaffService.timeRecords(widget.shopId,
            employeeId: m.id)
        .where((r) =>
            r.isUnexcused &&
            SalaryAdvance.monthKey(
                    r.clockOut ?? r.clockIn ?? r.createdAt) ==
                _monthKey)
        .length;

    final confirmed = await showAdaptiveFormSheet<bool>(
      context: context,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final net = Payslip.computeNet(
            baseSalary: m.baseSalary,
            bonuses: int.tryParse(bonuses.text.trim()) ?? 0,
            deductions: int.tryParse(deductions.text.trim()) ?? 0,
            advances: advances,
            overtime: overtime.amount,
            penalties: penalty,
            absences: absence.amount,
          );
          return AdaptiveFormFrame(
            title: 'Paie ${_monthLabel(_month)}',
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
                            color: Theme.of(ctx).semantic.warning),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                              '$unexcused départ${unexcused > 1 ? 's' : ''} '
                              'anticipé${unexcused > 1 ? 's' : ''} non '
                              'justifié${unexcused > 1 ? 's' : ''} ce mois-ci. '
                              'À vous de décider d\'une retenue.',
                              style: AppTextStyles.micro.copyWith(
                                  color: Theme.of(ctx).semantic.warningText)),
                        ),
                      ]),
                    ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: bonuses,
                    keyboardType: const TextInputType.numberWithOptions(),
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onChanged: (_) => setSheet(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Primes / heures supplémentaires',
                      hintText: '0',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: deductions,
                    keyboardType: const TextInputType.numberWithOptions(),
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onChanged: (_) => setSheet(() {}),
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
                    onTap: () => Navigator.of(sheetCtx).pop(true),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (confirmed != true || !mounted) return;

    await StaffService.generatePayslip(
      member: m,
      month: _monthKey,
      bonuses: int.tryParse(bonuses.text.trim()) ?? 0,
      deductions: int.tryParse(deductions.text.trim()) ?? 0,
    );
    if (!mounted) return;
    setState(() {});
    AppSnack.success(context, 'Fiche de paie générée.');
  }

  Future<void> _openSlip(StaffMember m, Payslip slip) async {
    final action = await showAdaptiveFormSheet<String>(
      context: context,
      builder: (sheetCtx) => AdaptiveFormFrame(
        title: 'Fiche ${_monthLabel(_month)}',
        subtitle: m.fullName,
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
                  onTap: () => Navigator.of(sheetCtx).pop('paid'),
                )
              else
                Center(
                  child: Text('Payée le ${_dayLabel(slip.paidAt!)}',
                      style: AppTextStyles.caption),
                ),
              const SizedBox(height: 6),
              Center(
                child: TextButton.icon(
                  onPressed: () => Navigator.of(sheetCtx).pop('delete'),
                  icon: Icon(Icons.delete_outline_rounded,
                      size: 18, color: Theme.of(ctxOf(sheetCtx)).semantic.danger),
                  label: Text('Supprimer la fiche',
                      style: AppTextStyles.label.copyWith(
                          color: Theme.of(ctxOf(sheetCtx)).semantic.dangerText)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (action == null || !mounted) return;
    if (action == 'paid') {
      await StaffService.markPaid(slip);
      if (!mounted) return;
      setState(() {});
      AppSnack.success(context, 'Fiche marquée payée.');
      return;
    }
    // Suppression : les avances retenues sont RENDUES, sinon elles seraient
    // perdues pour l'employé (marquées déduites sans fiche qui les porte).
    await StaffService.deletePayslip(slip);
    if (!mounted) return;
    setState(() {});
    AppSnack.success(context,
        'Fiche supprimée : avances, heures supplémentaires et casse rendues.');
  }

  /// Petit helper pour lire le thème dans un builder imbriqué.
  BuildContext ctxOf(BuildContext c) => c;

  static Widget _kv(String label, int amount) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Expanded(child: Text(label, style: AppTextStyles.bodySm)),
          Text(CurrencyFormatter.format(amount.toDouble()),
              style: AppTextStyles.bodySmBold),
        ]),
      );

  static String _monthLabel(DateTime d) {
    const months = [
      'janvier', 'février', 'mars', 'avril', 'mai', 'juin',
      'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre',
    ];
    return '${months[d.month - 1]} ${d.year}';
  }

  static String _dayLabel(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/${d.year}';
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
