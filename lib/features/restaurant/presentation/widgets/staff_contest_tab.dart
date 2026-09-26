import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;

import '../../../../core/services/staff_contest_service.dart';
import '../../../../core/services/staff_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_confirm_dialog.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../domain/entities/staff_contest.dart';
import '../../domain/entities/staff_member.dart';
import 'resto_empty_state.dart';
import 'resto_surfaces.dart';
import 'resto_table_listener.dart';

/// ONGLET PRIMES SPÉCIALES — les concours du patron (hotfix_165).
///
/// « Le meilleur vendeur de chawarmas de la quinzaine gagne 20 000 F. » Une
/// motivation ponctuelle, annoncée, datée, et versée à UNE personne à la fin.
///
/// La prime ne touche JAMAIS le salaire : elle ne passe par aucune fiche de
/// paie et n'entre pas dans la masse salariale. C'est ce qui la garde
/// exceptionnelle — fondue dans le bulletin, elle deviendrait un dû que
/// l'employé réclamerait le mois suivant.
class StaffContestTab extends StatefulWidget {
  final String shopId;
  const StaffContestTab({super.key, required this.shopId});

  @override
  State<StaffContestTab> createState() => _StaffContestTabState();
}

class _StaffContestTabState extends RestoTableListenerState<StaffContestTab> {
  @override
  List<String> get tables => const ['staff_contests', 'employees'];
  @override
  String get shopId => widget.shopId;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final list = StaffContestService.forShop(widget.shopId);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                    'Une prime versée à part du salaire, sur une période et '
                    'des conditions que vous annoncez.',
                    style: AppTextStyles.captionHint),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: () => _edit(null),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('Prime'),
                style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
              ),
            ],
          ),
        ),
        Expanded(
          child: list.isEmpty
              ? const RestoEmptyState(
                  icon: Icons.military_tech_outlined,
                  title: 'Aucune prime spéciale',
                  subtitle: 'Lancez un concours sur quelques jours : le '
                      'vainqueur touche la prime, sans impact sur son '
                      'salaire.',
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  itemCount: list.length,
                  itemBuilder: (_, i) =>
                      _ContestRow(contest: list[i], now: now,
                          onTap: () => _open(list[i])),
                ),
        ),
      ],
    );
  }

  /// Création d'un concours. Rien n'est obligatoire sauf le titre et la
  /// période : les conditions sont du texte libre, parce qu'aucune application
  /// ne sait mesurer « le plus souriant ».
  Future<void> _edit(StaffContest? existing) async {
    final title = TextEditingController(text: existing?.title ?? '');
    final conditions =
        TextEditingController(text: existing?.conditions ?? '');
    final prize = TextEditingController(
        text: (existing?.prize ?? 0) == 0 ? '' : '${existing!.prize}');
    var start = existing?.startDate ?? DateTime.now();
    var end = existing?.endDate ??
        DateTime.now().add(const Duration(days: 14));

    final confirmed = await showAdaptiveFormSheet<bool>(
      context: context,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (ctx, setSheet) => AdaptiveFormFrame(
          title: existing == null ? 'Nouvelle prime' : 'Modifier la prime',
          icon: Icons.military_tech_outlined,
          body: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: title,
                  autofocus: true,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                      labelText: 'Titre *',
                      hintText: 'Meilleur vendeur de chawarmas'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: conditions,
                  maxLines: 3,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Conditions',
                    hintText: 'Celui qui sert le plus de chawarmas, sans '
                        'aucune plainte client sur la période.',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: prize,
                  keyboardType: const TextInputType.numberWithOptions(),
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration:
                      const InputDecoration(labelText: 'Montant de la prime'),
                ),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: _DateField(
                      label: 'Début',
                      value: start,
                      onPick: (d) => setSheet(() => start = d),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _DateField(
                      label: 'Fin',
                      value: end,
                      onPick: (d) => setSheet(() => end = d),
                    ),
                  ),
                ]),
                const SizedBox(height: 18),
                AppPrimaryButton(
                  label: existing == null ? 'Lancer la prime' : 'Enregistrer',
                  icon: Icons.check_rounded,
                  fullWidth: true,
                  onTap: () => Navigator.of(sheetCtx).pop(true),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    if (title.text.trim().isEmpty) {
      AppSnack.info(context, 'Donnez un titre à la prime.');
      return;
    }
    final amount = int.tryParse(prize.text.trim()) ?? 0;
    if (existing == null) {
      await StaffContestService.create(
        shopId: widget.shopId,
        title: title.text,
        conditions: conditions.text,
        prize: amount,
        startDate: start,
        endDate: end,
      );
    } else {
      await StaffContestService.save(existing.copyWith(
        title: title.text.trim(),
        conditions: conditions.text.trim(),
        prize: amount,
        startDate: start,
        endDate: end.isBefore(start) ? start : end,
      ));
    }
    if (!mounted) return;
    setState(() {});
    AppSnack.success(context, 'Prime enregistrée.');
  }

  Future<void> _open(StaffContest c) async {
    final now = DateTime.now();
    final state = c.stateAt(now);
    final action = await showAdaptiveFormSheet<String>(
      context: context,
      builder: (sheetCtx) => AdaptiveFormFrame(
        title: c.title,
        subtitle: '${state.label} · ${_dayLabel(c.startDate)} → '
            '${_dayLabel(c.endDate)}',
        icon: Icons.military_tech_outlined,
        body: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (c.conditions.isNotEmpty) ...[
                const Text('Conditions', style: AppTextStyles.label),
                const SizedBox(height: 4),
                Text(c.conditions, style: AppTextStyles.bodySm),
                const SizedBox(height: 12),
              ],
              Row(children: [
                const Expanded(
                    child: Text('Prime', style: AppTextStyles.bodySm)),
                Text(CurrencyFormatter.format(c.prize.toDouble()),
                    style: AppTextStyles.subtitleBold),
              ]),
              if (c.hasWinner) ...[
                const Divider(height: 20),
                Row(children: [
                  Icon(Icons.emoji_events_rounded,
                      size: 18, color: Theme.of(sheetCtx).semantic.success),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(c.winnerName ?? 'Vainqueur',
                        style: AppTextStyles.bodyBold),
                  ),
                  if (c.isPaid)
                    Text('versée le ${_dayLabel(c.paidAt!)}',
                        style: AppTextStyles.micro),
                ]),
              ],
              const SizedBox(height: 16),
              if (!c.hasWinner)
                AppPrimaryButton(
                  label: state == ContestState.running
                      ? 'Désigner le vainqueur (avant la fin)'
                      : 'Désigner le vainqueur',
                  icon: Icons.emoji_events_outlined,
                  fullWidth: true,
                  onTap: () => Navigator.of(sheetCtx).pop('award'),
                )
              else if (!c.isPaid)
                AppPrimaryButton(
                  label: 'Verser la prime',
                  icon: Icons.payments_outlined,
                  fullWidth: true,
                  onTap: () => Navigator.of(sheetCtx).pop('pay'),
                ),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: TextButton.icon(
                    onPressed: () => Navigator.of(sheetCtx).pop('edit'),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('Modifier'),
                  ),
                ),
                if (c.hasWinner)
                  Expanded(
                    child: TextButton.icon(
                      onPressed: () => Navigator.of(sheetCtx).pop('unaward'),
                      icon: const Icon(Icons.undo_rounded, size: 18),
                      label: const Text('Changer'),
                    ),
                  ),
                Expanded(
                  child: TextButton.icon(
                    onPressed: () => Navigator.of(sheetCtx).pop('delete'),
                    icon: Icon(Icons.delete_outline_rounded,
                        size: 18, color: Theme.of(sheetCtx).semantic.danger),
                    label: Text('Supprimer',
                        style: AppTextStyles.label.copyWith(
                            color: Theme.of(sheetCtx).semantic.dangerText)),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
    if (action == null || !mounted) return;

    switch (action) {
      case 'edit':
        await _edit(c);
        return;
      case 'award':
        await _award(c);
        return;
      case 'pay':
        await StaffContestService.markPaid(c);
        if (!mounted) return;
        setState(() {});
        AppSnack.success(context,
            'Prime versée à ${c.winnerName ?? 'l\'employé'} — hors salaire.');
        return;
      case 'unaward':
        // Efface aussi le versement : la prime a été remise à quelqu'un qui
        // n'aurait pas dû la recevoir. Garder la trace du paiement fausserait
        // la caisse.
        await StaffContestService.clearWinner(c);
        if (!mounted) return;
        setState(() {});
        AppSnack.info(context, 'Vainqueur retiré.');
        return;
      case 'delete':
        final ok = await AppConfirmDialog.show(
          context: context,
          icon: Icons.delete_outline_rounded,
          iconColor: Theme.of(context).semantic.danger,
          title: 'Supprimer « ${c.title} » ?',
          body: const Text(
              'Le concours et son palmarès disparaissent. Une prime déjà '
              'versée reste sortie de la caisse.'),
          cancelLabel: 'Annuler',
          confirmLabel: 'Supprimer',
          onConfirm: () {},
        );
        if (ok != true || !mounted) return;
        await StaffContestService.delete(c);
        if (mounted) setState(() {});
        return;
    }
  }

  Future<void> _award(StaffContest c) async {
    final members = StaffService.forShop(widget.shopId, onlyActive: true);
    if (members.isEmpty) {
      AppSnack.info(context, 'Aucun employé actif à récompenser.');
      return;
    }
    final winner = await showAdaptiveFormSheet<StaffMember>(
      context: context,
      builder: (sheetCtx) => AdaptiveFormFrame(
        title: 'Qui a gagné ?',
        subtitle: c.title,
        icon: Icons.emoji_events_outlined,
        body: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final m in members)
              ListTile(
                leading: const Icon(Icons.person_outline_rounded),
                title: Text(m.fullName),
                subtitle: m.role.isEmpty ? null : Text(m.role),
                onTap: () => Navigator.of(sheetCtx).pop(m),
              ),
          ]),
        ),
      ),
    );
    if (winner == null || !mounted) return;
    await StaffContestService.award(c, winner);
    if (!mounted) return;
    setState(() {});
    AppSnack.success(context, '${winner.fullName} remporte la prime.');
  }

  static String _dayLabel(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}';
}

/// Une ligne de concours.
class _ContestRow extends StatelessWidget {
  final StaffContest contest;
  final DateTime now;
  final VoidCallback onTap;

  const _ContestRow(
      {required this.contest, required this.now, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    final state = contest.stateAt(now);
    final color = switch (state) {
      ContestState.upcoming => cs.onSurface.withValues(alpha: 0.5),
      ContestState.running => cs.primary,
      // « À départager » et « à verser » sont les deux états qui RÉCLAMENT un
      // geste : ils portent la même couleur d'alerte douce, pour que le gérant
      // les repère sans lire.
      ContestState.toAward => sem.warning,
      ContestState.awarded => sem.warning,
      ContestState.paid => sem.success,
    };
    final left = contest.daysLeftAt(now);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: restoGlassFill(context),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: sem.borderSubtle),
            ),
            child: Row(children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(contest.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.bodyBold
                            .copyWith(color: cs.onSurface)),
                    Text(
                        [
                          state.label,
                          if (state == ContestState.running)
                            left == 0
                                ? 'dernier jour'
                                : 'encore $left jour${left > 1 ? 's' : ''}',
                          if (contest.hasWinner) contest.winnerName!,
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.caption.copyWith(color: color)),
                  ],
                ),
              ),
              Text(CurrencyFormatter.format(contest.prize.toDouble()),
                  style: AppTextStyles.bodySmBold),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Sélecteur de date au gabarit d'un champ de formulaire.
class _DateField extends StatelessWidget {
  final String label;
  final DateTime value;
  final ValueChanged<DateTime> onPick;

  const _DateField(
      {required this.label, required this.value, required this.onPick});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: () async {
          final d = await showDatePicker(
            context: context,
            initialDate: value,
            firstDate: DateTime.now().subtract(const Duration(days: 365)),
            lastDate: DateTime.now().add(const Duration(days: 365)),
          );
          if (d != null) onPick(d);
        },
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: label,
            suffixIcon: const Icon(Icons.calendar_today_rounded, size: 16),
          ),
          child: Text(
              '${value.day.toString().padLeft(2, '0')}/'
              '${value.month.toString().padLeft(2, '0')}/${value.year}',
              style: AppTextStyles.body),
        ),
      );
}
