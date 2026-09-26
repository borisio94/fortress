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

part 'staff_payroll_tab.sections.dart';
part 'staff_payroll_tab.sheets.dart';

// L'onglet PAIE de la page Personnel.
//
// Sorti de `restaurant_staff_page.dart` (où il était un `part`) le 26/09/2026,
// lot « classes géantes » : une classe privée d'une page sous `AppScaffold` ne
// se monte pas en test. Public et dans son fichier, comme Notation
// (`StaffRatingTab`) et Primes (`StaffContestTab`), il reçoit un banc de test
// avant qu'on découpe sa classe d'état.
//
// Découpé le même jour : ce fichier garde l'onglet, ses données et ses
// décisions (refus, écritures, messages) ; les feuilles de saisie vivent dans
// `staff_payroll_tab.sheets.dart`, les listes dans
// `staff_payroll_tab.sections.dart`.

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
                    _AdvancesList(
                      list: StaffService.advances(widget.shopId,
                          month: _monthKey),
                      onTap: _advanceActions,
                    ),
                    const SizedBox(height: 16),
                    const Text('Casse imputée', style: AppTextStyles.bodyBold),
                    const SizedBox(height: 6),
                    _PenaltiesList(
                      list: StaffService.penalties(widget.shopId),
                      onTap: _penaltyActions,
                    ),
                    const SizedBox(height: 16),
                    const Text('Mises à pied et congés',
                        style: AppTextStyles.bodyBold),
                    const SizedBox(height: 6),
                    _AbsencesList(
                      list: StaffService.absences(widget.shopId),
                      onTap: _absenceActions,
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  Future<void> _addAdvance(StaffMember m) async {
    final input = await showAdaptiveFormSheet<({int amount, String reason})>(
      context: context,
      builder: (_) => _AdvanceSheet(member: m, month: _month),
    );
    if (input == null || input.amount <= 0 || !mounted) return;
    // Le motif est exigé ici et NULLE PART pour la quinzaine : c'est toute la
    // différence entre une faveur et un droit. Sans lui, plus rien ne
    // distingue les deux au moment de relire le mois.
    if (input.reason.trim().isEmpty) {
      AppSnack.info(context,
          'Indiquez le motif de l\'avance. Sans motif, versez plutôt la '
          'quinzaine.');
      return;
    }
    await StaffService.recordAdvance(
      member: m,
      amount: input.amount,
      reason: input.reason.trim(),
      month: _monthKey,
    );
    if (!mounted) return;
    setState(() {});
    AppSnack.success(context, 'Avance enregistrée.');
  }

  /// Les trois mouvements d'argent d'un employé, derrière un seul bouton
  /// (`_MoneyMenuSheet`), puis la feuille du mouvement choisi.
  Future<void> _moneyActions(StaffMember m) async {
    final action = await showAdaptiveFormSheet<String>(
      context: context,
      builder: (_) => _MoneyMenuSheet(
        member: m,
        month: _month,
        taken: StaffService.fortnightTaken(widget.shopId, m.id, _monthKey),
        cap: SalaryAdvance.fortnightCap(m.baseSalary),
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

    final value = await showAdaptiveFormSheet<int>(
      context: context,
      builder: (_) => _FortnightSheet(
        member: m,
        month: _month,
        cap: cap,
        taken: taken,
        left: left,
        cash: cash,
      ),
    );
    if (value == null || !mounted) return;

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
    final input = await showAdaptiveFormSheet<_PenaltyInput>(
      context: context,
      builder: (_) => _PenaltySheet(
          member: m, shopId: widget.shopId, monthKey: _monthKey),
    );
    if (input == null || !mounted) return;

    if (input.item.trim().isEmpty || input.amount <= 0) {
      AppSnack.info(context, 'Indiquez le bien et sa valeur.');
      return;
    }
    if (input.reason.trim().isEmpty) {
      AppSnack.info(
          context,
          'Les circonstances sont obligatoires : sans elles, la retenue est '
          'indéfendable le jour où elle est contestée.');
      return;
    }
    await StaffService.recordPenalty(
      member: m,
      itemLabel: input.item,
      amount: input.amount,
      reason: input.reason,
      mode: input.mode,
      percentPerMonth: input.percent,
      startMonth: _monthKey,
    );
    if (!mounted) return;
    setState(() {});
    AppSnack.success(
        context,
        input.mode == PenaltyMode.cashRepaid
            ? 'Casse enregistrée — salaire non impacté.'
            : 'Casse enregistrée, retenue à la prochaine paie.');
  }

  Future<void> _absenceActions(StaffAbsence a) async {
    final action = await showAdaptiveFormSheet<String>(
      context: context,
      builder: (_) => _AbsenceSheet(absence: a),
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

    final input =
        await showAdaptiveFormSheet<({int bonuses, int deductions})>(
      context: context,
      builder: (_) => _GenerateSheet(
        member: m,
        month: _month,
        advances:
            StaffService.pendingAdvances(widget.shopId, m.id, _monthKey),
        minutes: StaffService.minutesInMonth(widget.shopId, m.id, _monthKey),
        overtime:
            StaffService.pendingOvertime(widget.shopId, m.id, _monthKey),
        penalty: StaffService.penaltyDueFor(widget.shopId, m.id, _monthKey),
        absence: StaffService.absenceDueFor(m, _monthKey),
        unexcused: unexcused,
      ),
    );
    if (input == null || !mounted) return;

    await StaffService.generatePayslip(
      member: m,
      month: _monthKey,
      bonuses: input.bonuses,
      deductions: input.deductions,
    );
    if (!mounted) return;
    setState(() {});
    AppSnack.success(context, 'Fiche de paie générée.');
  }

  Future<void> _openSlip(StaffMember m, Payslip slip) async {
    final action = await showAdaptiveFormSheet<String>(
      context: context,
      builder: (_) => _SlipSheet(member: m, slip: slip, month: _month),
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
}

/// Une ligne « libellé … montant » d'un détail de paie.
Widget _kv(String label, int amount) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Expanded(child: Text(label, style: AppTextStyles.bodySm)),
        Text(CurrencyFormatter.format(amount.toDouble()),
            style: AppTextStyles.bodySmBold),
      ]),
    );

String _monthLabel(DateTime d) {
  const months = [
    'janvier', 'février', 'mars', 'avril', 'mai', 'juin',
    'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre',
  ];
  return '${months[d.month - 1]} ${d.year}';
}

String _dayLabel(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/'
    '${d.month.toString().padLeft(2, '0')}/${d.year}';
