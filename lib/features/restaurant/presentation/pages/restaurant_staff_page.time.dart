part of 'restaurant_staff_page.dart';

// L'onglet Pointage.

// ═══════════════════════════════════════════════════════════════════════
//  Onglet POINTAGE
// ═══════════════════════════════════════════════════════════════════════
class _TimeTab extends StatefulWidget {
  final String shopId;
  const _TimeTab({required this.shopId});
  @override
  State<_TimeTab> createState() => _TimeTabState();
}

class _TimeTabState extends _StaffTabState<_TimeTab> {
  @override
  List<String> get tables => const ['time_records', 'employees'];
  @override
  String get shopId => widget.shopId;

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    final cs = Theme.of(context).colorScheme;
    final onDuty = StaffService.onDuty(widget.shopId);
    final records = StaffService.timeRecords(widget.shopId).take(60).toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Icon(Icons.groups_rounded, size: 18, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    onDuty.isEmpty
                        ? 'Personne en service'
                        : '${onDuty.length} en service : '
                            '${onDuty.map((r) => r.employeeName ?? '?').join(', ')}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.bodySm),
              ),
              TextButton.icon(
                onPressed: _manualEntry,
                icon: const Icon(Icons.edit_calendar_outlined, size: 18),
                label: const Text('Saisir'),
              ),
            ],
          ),
        ),
        Expanded(
          child: records.isEmpty
              ? const RestoEmptyState(
                  icon: Icons.schedule_outlined,
                  title: 'Aucun pointage',
                  subtitle: 'Ouvrez la badgeuse (icône en haut) sur la '
                      'tablette de l\'entrée du personnel.',
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  itemCount: records.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final r = records[i];
                    // Le verdict prime sur l'état du service dans l'icône : un
                    // pointage qui attend une décision doit se repérer sans
                    // lire, au milieu de soixante lignes identiques.
                    final needsCall = r.excuseToJudge || r.overtimeToSettle;
                    return _Row(
                      onTap: () => _recordActions(r),
                      child: Row(children: [
                        Icon(
                            r.isOpen
                                ? Icons.play_circle_outline_rounded
                                : needsCall
                                    ? Icons.help_outline_rounded
                                    : Icons.check_circle_outline_rounded,
                            size: 18,
                            color: r.isOpen
                                ? sem.warning
                                : needsCall
                                    ? sem.warning
                                    : sem.success),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(r.employeeName ?? 'Employé',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTextStyles.bodyBold
                                      .copyWith(color: cs.onSurface)),
                              Text(
                                  '${_stamp(r.clockIn)} → '
                                  '${r.isOpen ? 'en cours' : _stamp(r.clockOut)}'
                                  '${r.method == 'manual' ? ' · saisi' : ''}',
                                  style: AppTextStyles.caption),
                              if (_verdictLabel(r) != null)
                                Text(_verdictLabel(r)!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppTextStyles.micro
                                        .copyWith(color: _verdictColor(r, sem))),
                            ],
                          ),
                        ),
                        Text(
                            TimeRecord.formatMinutes(
                                r.durationMinutes ?? r.worked.inMinutes),
                            style: AppTextStyles.bodySmBold),
                      ]),
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// Ce qu'un pointage raconte en une ligne : rien s'il est normal, le verdict
  /// sinon. Écrire « à l'heure » sur chaque ligne noierait les deux qui
  /// demandent quelque chose.
  static String? _verdictLabel(TimeRecord r) {
    if (r.isEarly) {
      final t = 'parti ${TimeRecord.formatMinutes(r.earlyMinutes)} plus tôt';
      return switch (r.excuseStatus) {
        ExcuseStatus.pending => '$t · excuse à juger',
        ExcuseStatus.accepted => '$t · excusé',
        ExcuseStatus.refused => '$t · excuse refusée',
        ExcuseStatus.none => '$t · sans excuse',
      };
    }
    if (r.hasOvertime) {
      final t = '+${TimeRecord.formatMinutes(r.overtimeMinutes)}';
      if (r.overtimeSettled) {
        return r.overtimeSettlement == OvertimeSettlement.paidNow
            ? '$t · payées'
            : '$t · portées sur la paie';
      }
      return r.overtimeSettlement == OvertimeSettlement.onPayslip
          ? '$t · en attente de la paie'
          : '$t · à régler';
    }
    return null;
  }

  /// Couleur du VERDICT écrit sous un pointage — une couleur de TEXTE, donc
  /// les variantes `*Text` (le token suit son fond : ici le verre clair).
  static Color? _verdictColor(TimeRecord r, AppSemanticColors sem) {
    if (r.excuseToJudge || r.overtimeToSettle) return sem.warningText;
    if (r.isUnexcused) return sem.dangerText;
    if (r.hasOvertime) return sem.successText;
    return null;
  }

  /// Le sheet où le gérant TRANCHE : accepter ou refuser une excuse, payer des
  /// heures supplémentaires tout de suite ou les reporter sur la paie.
  ///
  /// Rien ne se décide ailleurs. C'est le seul écran qui engage de l'argent
  /// sur un pointage, et il ne le fait jamais sans un geste explicite.
  Future<void> _recordActions(TimeRecord r) async {
    final action = await showAdaptiveFormSheet<String>(
      context: context,
      builder: (sheetCtx) {
        final sem = Theme.of(sheetCtx).semantic;
        return AdaptiveFormFrame(
          title: r.employeeName ?? 'Pointage',
          subtitle: '${_stamp(r.clockIn)} → '
              '${r.isOpen ? 'en cours' : _stamp(r.clockOut)}',
          icon: Icons.schedule_outlined,
          body: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  const Expanded(
                      child: Text('Durée travaillée',
                          style: AppTextStyles.bodySm)),
                  Text(
                      TimeRecord.formatMinutes(
                          r.durationMinutes ?? r.worked.inMinutes),
                      style: AppTextStyles.bodySmBold),
                ]),
                if (r.scheduledEnd != null)
                  Row(children: [
                    Expanded(
                        child: Text('Fin prévue',
                            style: AppTextStyles.captionHint)),
                    Text(_stamp(r.scheduledEnd), style: AppTextStyles.caption),
                  ]),

                // ── DÉPART ANTICIPÉ ──────────────────────────────────────
                if (r.isEarly) ...[
                  const Divider(height: 22),
                  Row(children: [
                    Icon(Icons.logout_rounded, size: 16, color: sem.warning),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                          'Parti ${TimeRecord.formatMinutes(r.earlyMinutes)} '
                          'avant la fermeture',
                          style: AppTextStyles.bodySmBold),
                    ),
                  ]),
                  const SizedBox(height: 6),
                  Text(
                      (r.earlyExcuse ?? '').isEmpty
                          ? 'Aucune excuse n\'a été donnée à la badgeuse.'
                          : '« ${r.earlyExcuse} »',
                      style: AppTextStyles.bodySm),
                  const SizedBox(height: 4),
                  Text(r.excuseStatus.label,
                      style: AppTextStyles.micro.copyWith(
                          color: switch (r.excuseStatus) {
                        ExcuseStatus.accepted => sem.successText,
                        ExcuseStatus.refused => sem.dangerText,
                        _ => sem.warningText,
                      })),
                  // Les deux boutons restent offerts même après décision : un
                  // gérant qui a refusé trop vite, puis à qui l'employé
                  // apporte le justificatif le lendemain, doit pouvoir se
                  // dédire sans supprimer le pointage.
                  ...[
                    const SizedBox(height: 10),
                    Row(children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () =>
                              Navigator.of(sheetCtx).pop('accept'),
                          icon: const Icon(Icons.check_rounded, size: 16),
                          label: const Text('Accepter'),
                          style: OutlinedButton.styleFrom(
                              minimumSize: const Size(0, 40)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () =>
                              Navigator.of(sheetCtx).pop('refuse'),
                          icon: const Icon(Icons.close_rounded, size: 16),
                          label: const Text('Refuser'),
                          style: OutlinedButton.styleFrom(
                              minimumSize: const Size(0, 40),
                              foregroundColor: sem.dangerText),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 4),
                    Text(
                        'Un refus ne retient rien automatiquement : il vous '
                        'le rappelle au moment de la paie.',
                        style: AppTextStyles.micro),
                  ],
                ],

                // ── HEURES SUPPLÉMENTAIRES ───────────────────────────────
                if (r.hasOvertime) ...[
                  const Divider(height: 22),
                  Row(children: [
                    Icon(Icons.more_time_rounded, size: 16,
                        color: sem.success),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                          '${TimeRecord.formatMinutes(r.overtimeMinutes)} '
                          'au-delà de la fermeture',
                          style: AppTextStyles.bodySmBold),
                    ),
                    Text(
                        CurrencyFormatter.format(
                            r.overtimeAmount.toDouble()),
                        style: AppTextStyles.bodySmBold),
                  ]),
                  if (r.overtimeRate <= 0) ...[
                    const SizedBox(height: 4),
                    Text(
                        'Aucun taux horaire n\'est réglé pour cette fonction : '
                        'les heures sont comptées mais valorisées à zéro. '
                        'Réglez-le dans l\'onglet Équipe.',
                        style: AppTextStyles.micro.copyWith(
                            color: sem.warningText)),
                  ] else
                    Text(
                        'Taux : '
                        '${CurrencyFormatter.format(r.overtimeRate.toDouble())} '
                        'de l\'heure, au prorata des minutes.',
                        style: AppTextStyles.micro),
                  const SizedBox(height: 10),
                  if (r.overtimeSettled)
                    Text(
                        r.overtimeSettlement == OvertimeSettlement.paidNow
                            ? 'Déjà payées de la main à la main.'
                            : 'Déjà portées sur une fiche de paie.',
                        style: AppTextStyles.caption
                            .copyWith(color: sem.successText))
                  else ...[
                    Row(children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () =>
                              Navigator.of(sheetCtx).pop('ot_now'),
                          icon: const Icon(Icons.payments_outlined, size: 16),
                          label: const Text('Payer de suite'),
                          style: OutlinedButton.styleFrom(
                              minimumSize: const Size(0, 40)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () =>
                              Navigator.of(sheetCtx).pop('ot_payslip'),
                          icon: const Icon(Icons.event_note_outlined,
                              size: 16),
                          label: const Text('Sur la paie'),
                          style: OutlinedButton.styleFrom(
                              minimumSize: const Size(0, 40)),
                        ),
                      ),
                    ]),
                    if (r.overtimeSettlement == OvertimeSettlement.onPayslip)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                            'Reportées : elles s\'ajouteront à la fiche du '
                            'mois, avec la mention des heures.',
                            style: AppTextStyles.micro
                                .copyWith(color: sem.successText)),
                      ),
                  ],
                ],

                const SizedBox(height: 14),
                Center(
                  child: TextButton.icon(
                    onPressed: () => Navigator.of(sheetCtx).pop('delete'),
                    icon: Icon(Icons.delete_outline_rounded,
                        size: 18, color: sem.danger),
                    label: Text('Supprimer ce pointage',
                        style: AppTextStyles.label
                            .copyWith(color: sem.dangerText)),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (action == null || !mounted) return;

    switch (action) {
      case 'accept':
      case 'refuse':
        await StaffService.judgeExcuse(r, action == 'accept');
        if (!mounted) return;
        setState(() {});
        AppSnack.success(
            context,
            action == 'accept'
                ? 'Départ excusé.'
                : 'Excuse refusée — rien n\'a été retenu.');
        return;
      case 'ot_now':
        await StaffService.settleOvertime(r, OvertimeSettlement.paidNow);
        if (!mounted) return;
        setState(() {});
        AppSnack.success(
            context,
            'Heures payées : '
            '${CurrencyFormatter.format(r.overtimeAmount.toDouble())} '
            'sortis de la caisse.');
        return;
      case 'ot_payslip':
        await StaffService.settleOvertime(r, OvertimeSettlement.onPayslip);
        if (!mounted) return;
        setState(() {});
        AppSnack.success(context, 'Reportées sur la paie du mois.');
        return;
      case 'delete':
        final ok = await AppConfirmDialog.show(
          context: context,
          icon: Icons.delete_outline_rounded,
          iconColor: Theme.of(context).semantic.danger,
          title: 'Supprimer ce pointage ?',
          body: Text('${r.employeeName ?? 'Employé'} · '
              '${_stamp(r.clockIn)} → '
              '${r.isOpen ? 'en cours' : _stamp(r.clockOut)}'),
          cancelLabel: 'Annuler',
          confirmLabel: 'Supprimer',
          onConfirm: () {},
        );
        if (ok != true || !mounted) return;
        await StaffService.deleteTimeRecord(r);
        if (mounted) setState(() {});
        return;
    }
  }

  /// Saisie manuelle d'un service — l'oubli de badge est la règle, pas
  /// l'exception : sans rattrapage, les heures du mois sont fausses.
  Future<void> _manualEntry() async {
    final members = StaffService.forShop(widget.shopId, onlyActive: true);
    if (members.isEmpty) {
      AppSnack.info(context, 'Ajoutez d\'abord un employé.');
      return;
    }
    final member = await showAdaptiveFormSheet<StaffMember>(
      context: context,
      builder: (_) => AdaptiveFormFrame(
        title: 'Qui a travaillé ?',
        icon: Icons.person_search_outlined,
        body: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final m in members)
              ListTile(
                leading: const Icon(Icons.badge_outlined),
                title: Text(m.fullName),
                subtitle: m.role.isEmpty ? null : Text(m.role),
                onTap: () => Navigator.of(context).pop(m),
              ),
          ]),
        ),
      ),
    );
    if (member == null || !mounted) return;

    final day = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime.now().subtract(const Duration(days: 90)),
      lastDate: DateTime.now(),
    );
    if (day == null || !mounted) return;

    final start = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 8, minute: 0),
      helpText: 'Heure d\'arrivée',
    );
    if (start == null || !mounted) return;
    final end = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 18, minute: 0),
      helpText: 'Heure de départ',
    );
    if (end == null || !mounted) return;

    final from =
        DateTime(day.year, day.month, day.day, start.hour, start.minute);
    var to = DateTime(day.year, day.month, day.day, end.hour, end.minute);
    // Service de nuit : une sortie antérieure à l'entrée est le lendemain.
    // Sans ça, la durée serait nulle et les heures de nuit disparaîtraient.
    if (to.isBefore(from)) to = to.add(const Duration(days: 1));

    await StaffService.recordManual(
        member: member, start: from, end: to, note: 'Saisie gérant');
    if (!mounted) return;
    setState(() {});
    AppSnack.success(context, 'Pointage enregistré.');
  }

  static String _stamp(DateTime? d) {
    if (d == null) return '—';
    return '${d.day.toString().padLeft(2, '0')}/'
        '${d.month.toString().padLeft(2, '0')} '
        '${d.hour.toString().padLeft(2, '0')}:'
        '${d.minute.toString().padLeft(2, '0')}';
  }
}
