part of 'staff_editor_sheet.dart';

// Les DÉCISIONS de la fiche employé : mise à pied, congé payé, levée,
// archivage, suppression. Les feuilles rendent ce qui a été saisi, et c'est la
// fiche qui décide quoi en faire (refus, écriture, message) — exactement comme
// avant l'extraction, où ces contrôles se faisaient déjà après la fermeture.
//
// Les feuilles à champs sont des widgets À ÉTAT, propriétaires de leurs
// contrôleurs : ils étaient créés dans les méthodes de la fiche et jamais
// libérés. Extraites de `_StaffEditorState` le 26/09/2026 (lot « classes
// géantes »), sous le banc `test/widget/staff_editor_sheet_test.dart`.

/// Ce que la feuille d'absence a saisi — le motif TEL QUE TAPÉ : la fiche le
/// contrôle rogné, mais l'enregistre brut, comme avant l'extraction.
typedef _AbsenceInput = ({
  DateTime start,
  DateTime end,
  String reason,
  bool isPaid,
});

/// MISE À PIED ou CONGÉ PAYÉ : deux dates, un motif, et pour la mise à pied
/// la question du solde.
class _AbsenceSheet extends StatefulWidget {
  final StaffMember member;
  final String shopId;
  final AbsenceKind kind;

  const _AbsenceSheet({
    required this.member,
    required this.shopId,
    required this.kind,
  });

  @override
  State<_AbsenceSheet> createState() => _AbsenceSheetState();
}

class _AbsenceSheetState extends State<_AbsenceSheet> {
  var _start = DateTime.now();
  var _end = DateTime.now();
  final _reason = TextEditingController();

  // Sans solde par défaut pour une mise à pied ; un congé payé l'est par
  // définition et la question ne se pose pas.
  late var _isPaid = widget.kind == AbsenceKind.paidLeave;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.member;
    final kind = widget.kind;
    final days = StaffAbsence(
      id: '_', shopId: widget.shopId, employeeId: m.id, kind: kind,
      startDate: _start, endDate: _end, reason: '',
      createdAt: DateTime.now(),
    ).days;
    final perDay = StaffAbsence.dailyRate(m.baseSalary);
    return AdaptiveFormFrame(
      title: kind.label,
      subtitle: m.fullName,
      icon: kind == AbsenceKind.suspension
          ? Icons.gavel_rounded
          : Icons.beach_access_rounded,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
                kind == AbsenceKind.suspension
                    ? 'L\'employé est écarté du service. Il ne pourra '
                        'pas badger pendant cette période.'
                    : 'Le salaire est maintenu intégralement. Il ne '
                        'pourra pas badger pendant cette période.',
                style: AppTextStyles.captionHint),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: _DayField(
                  label: 'Du',
                  value: _start,
                  onPick: (d) => setState(() {
                    _start = d;
                    if (_end.isBefore(_start)) _end = _start;
                  }),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _DayField(
                  label: 'Au (inclus)',
                  value: _end,
                  onPick: (d) => setState(() => _end = d),
                ),
              ),
            ]),
            const SizedBox(height: 6),
            Text('$days jour${days > 1 ? 's' : ''}',
                style: AppTextStyles.caption),
            const SizedBox(height: 10),
            TextField(
              controller: _reason,
              autofocus: true,
              maxLines: 2,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: 'Motif *',
                hintText: kind == AbsenceKind.suspension
                    ? 'Absence répétée sans prévenir, 3e fois'
                    : 'Congé annuel, mariage, deuil…',
              ),
            ),
            if (kind == AbsenceKind.suspension) ...[
              const SizedBox(height: 8),
              SwitchListTile(
                value: _isPaid,
                onChanged: (v) => setState(() => _isPaid = v),
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Maintenir le salaire',
                    style: AppTextStyles.bodySm),
                // La mise à pied CONSERVATOIRE : on écarte le temps de
                // vérifier les faits. Sanctionner avant d'avoir vérifié
                // est exactement ce qu'elle sert à éviter.
                subtitle: Text(
                    _isPaid
                        ? 'Mise à pied conservatoire : rien n\'est '
                            'retenu, le temps de vérifier les faits.'
                        : perDay <= 0
                            ? 'Aucun salaire de base renseigné : rien ne '
                                'sera retenu.'
                            : 'Retenue de '
                                '${CurrencyFormatter.format((perDay * days).toDouble())} '
                                '($days × ${CurrencyFormatter.format(perDay.toDouble())} '
                                'par jour) sur la prochaine paie.',
                    style: AppTextStyles.micro),
              ),
            ],
            const SizedBox(height: 14),
            AppPrimaryButton(
              label: 'Enregistrer',
              icon: Icons.check_rounded,
              fullWidth: true,
              onTap: () => Navigator.of(context).pop<_AbsenceInput>((
                start: _start,
                end: _end,
                reason: _reason.text,
                isPaid: _isPaid,
              )),
            ),
          ],
        ),
      ),
    );
  }
}

/// SUPPRESSION DÉFINITIVE. Le motif est exigé, et la boîte dit exactement ce
/// qui reste — un gérant qui croit tout effacer serait très surpris de
/// retrouver les bulletins, et très ennuyé de ne PAS les retrouver.
///
/// Rend le motif TEL QUE TAPÉ (éventuellement vide : c'est la fiche qui le
/// refuse).
class _DeleteSheet extends StatefulWidget {
  final StaffMember member;

  const _DeleteSheet({required this.member});

  @override
  State<_DeleteSheet> createState() => _DeleteSheetState();
}

class _DeleteSheetState extends State<_DeleteSheet> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AdaptiveFormFrame(
      title: 'Supprimer ${widget.member.fullName} ?',
      icon: Icons.delete_forever_rounded,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
                'Sa fiche disparaît des listes, de la paie et de la '
                'notation. Ses pointages, avances et bulletins déjà émis '
                'RESTENT : ils portent son nom et alimentent des totaux '
                'déjà vérifiés.',
                style: AppTextStyles.bodySm),
            const SizedBox(height: 8),
            Text(
                'Pour un départ ordinaire, préférez « Archiver » : la fiche '
                'sort de l\'équipe active et se réactive d\'un bouton.',
                style: AppTextStyles.captionHint),
            const SizedBox(height: 12),
            TextField(
              controller: _reason,
              autofocus: true,
              maxLines: 2,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Motif de la suppression *',
                hintText: 'Fiche créée par erreur, doublon…',
              ),
            ),
            const SizedBox(height: 18),
            AppPrimaryButton(
              label: 'Supprimer définitivement',
              icon: Icons.delete_forever_rounded,
              fullWidth: true,
              onTap: () => Navigator.of(context).pop(_reason.text),
            ),
          ],
        ),
      ),
    );
  }
}

/// Le bloc « Décisions » d'une fiche existante : l'absence en cours, puis
/// mise à pied, congé, archivage et suppression.
class _DecisionsPanel extends StatelessWidget {
  final StaffMember member;

  /// L'absence qui court aujourd'hui, s'il y en a une.
  final StaffAbsence? liveAbsence;
  final VoidCallback onLift;
  final ValueChanged<AbsenceKind> onAbsence;
  final VoidCallback onArchive;
  final VoidCallback onDelete;

  const _DecisionsPanel({
    required this.member,
    required this.liveAbsence,
    required this.onLift,
    required this.onAbsence,
    required this.onArchive,
    required this.onDelete,
  });

  static String _dayShort(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    final m = member;
    final live = liveAbsence;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 26),
        const Text('Décisions', style: AppTextStyles.label),
        const SizedBox(height: 2),
        Text(
            'Chacune demande un motif écrit : c\'est ce qui reste le '
            'jour où elle est contestée.',
            style: AppTextStyles.captionHint),
        const SizedBox(height: 8),
        // ABSENCE EN COURS — affichée avant les boutons : prononcer une
        // seconde mise à pied par-dessus une première est une erreur de
        // saisie qu'on évite en la montrant, pas en la refusant.
        if (live != null) ...[
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: sem.warning.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(10),
              border:
                  Border.all(color: sem.warning.withValues(alpha: 0.35)),
            ),
            child: Row(children: [
              Icon(Icons.event_busy_rounded, size: 16,
                  color: sem.warning),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    '${live.kind.label} jusqu\'au '
                    '${_dayShort(live.endDate)}'
                    '${live.isPaid ? ' (payée)' : ' (sans solde)'}'
                    '\n« ${live.reason} »',
                    style: AppTextStyles.caption),
              ),
              TextButton(
                onPressed: onLift,
                child: const Text('Lever'),
              ),
            ]),
          ),
          const SizedBox(height: 8),
        ],
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => onAbsence(AbsenceKind.suspension),
              icon: const Icon(Icons.gavel_rounded, size: 16),
              label: const Text('Mise à pied'),
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 40),
                  foregroundColor: sem.warningText),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => onAbsence(AbsenceKind.paidLeave),
              icon: const Icon(Icons.beach_access_rounded, size: 16),
              label: const Text('Congé payé'),
              style:
                  OutlinedButton.styleFrom(minimumSize: const Size(0, 40)),
            ),
          ),
        ]),
        const SizedBox(height: 4),
        Row(children: [
          Expanded(
            child: TextButton.icon(
              onPressed: onArchive,
              icon: Icon(
                  m.isActive
                      ? Icons.archive_outlined
                      : Icons.unarchive_outlined,
                  size: 18,
                  color: sem.warning),
              label: Text(m.isActive ? 'Archiver' : 'Réactiver',
                  style:
                      AppTextStyles.label.copyWith(color: sem.warningText)),
            ),
          ),
          Expanded(
            child: TextButton.icon(
              onPressed: onDelete,
              icon: Icon(Icons.delete_forever_rounded,
                  size: 18, color: sem.danger),
              label: Text('Supprimer',
                  style:
                      AppTextStyles.label.copyWith(color: sem.dangerText)),
            ),
          ),
        ]),
      ],
    );
  }
}
