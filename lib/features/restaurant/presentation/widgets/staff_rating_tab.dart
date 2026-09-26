import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;

import '../../../../core/services/staff_score_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../domain/entities/staff_member.dart';
import '../../domain/entities/staff_rating.dart';
import 'resto_empty_state.dart';
import 'resto_surfaces.dart';
import 'resto_table_listener.dart';
import 'staff_score_gauge.dart';

/// ONGLET NOTATION — la conduite de chacun, sur 10 points (hotfix_165).
///
/// Le classement du mois, meilleur en tête. Chaque employé part de 10 ; une
/// plainte client jugée fondée en retire, un service remarquable en ajoute.
///
/// Ce que cet écran refuse de faire : décider à la place du gérant. Il ne juge
/// aucune plainte, ne retire aucun point tout seul, et ne licencie personne
/// quand la note descend — il affiche « à remplacer d'urgence » et s'arrête
/// là. Une note est un outil de conversation, pas une sanction automatique.
class StaffRatingTab extends StatefulWidget {
  final String shopId;
  const StaffRatingTab({super.key, required this.shopId});

  @override
  State<StaffRatingTab> createState() => _StaffRatingTabState();
}

class _StaffRatingTabState extends RestoTableListenerState<StaffRatingTab> {
  @override
  List<String> get tables => const ['staff_ratings', 'employees'];
  @override
  String get shopId => widget.shopId;

  late DateTime _month = DateTime.now();

  String get _monthKey => StaffScoreService.monthKey(_month);

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    final ranking = StaffScoreService.ranking(widget.shopId, month: _monthKey);
    final flagged = ranking.where((e) => e.score.needsReplacement).length;

    return Column(
      children: [
        // Sélecteur de mois : la note repart à 10 le 1er, et le gérant doit
        // pouvoir relire le mois écoulé pour en parler à son équipe.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(
            children: [
              IconButton(
                onPressed: () => setState(
                    () => _month = DateTime(_month.year, _month.month - 1)),
                icon: const Icon(Icons.chevron_left_rounded),
              ),
              Expanded(
                child: Text(_monthLabel(_month),
                    textAlign: TextAlign.center,
                    style: AppTextStyles.bodyBold),
              ),
              IconButton(
                onPressed: () => setState(
                    () => _month = DateTime(_month.year, _month.month + 1)),
                icon: const Icon(Icons.chevron_right_rounded),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
              flagged == 0
                  ? 'Chacun démarre le mois à 10 points. Touchez un employé '
                      'pour retirer ou ajouter des points.'
                  : '$flagged employé${flagged > 1 ? 's' : ''} sous la barre '
                      'des ${StaffScore.urgentThreshold} points.',
              style: flagged == 0
                  ? AppTextStyles.captionHint
                  : AppTextStyles.caption.copyWith(color: sem.dangerText)),
        ),
        Expanded(
          child: ranking.isEmpty
              ? const RestoEmptyState(
                  icon: Icons.emoji_events_outlined,
                  title: 'Aucun employé actif',
                  subtitle: 'Inscrivez votre équipe dans l\'onglet Équipe '
                      'pour commencer à la noter.',
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  itemCount: ranking.length,
                  itemBuilder: (_, i) {
                    final e = ranking[i];
                    return _RankRow(
                      rank: i + 1,
                      member: e.member,
                      score: e.score,
                      onTap: () => _openMember(e.member),
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// Fiche de notation d'un employé : sa note, son historique du mois, et les
  /// deux gestes possibles.
  Future<void> _openMember(StaffMember m) async {
    final events = StaffScoreService.ratings(widget.shopId,
        employeeId: m.id, month: _monthKey);
    final score = StaffScoreService.scoreOf(widget.shopId, m.id, _monthKey);

    final action = await showAdaptiveFormSheet<String>(
      context: context,
      builder: (sheetCtx) {
        final sem = Theme.of(sheetCtx).semantic;
        return AdaptiveFormFrame(
          title: m.fullName,
          subtitle: 'Note de ${_monthLabel(_month)}',
          icon: Icons.grade_outlined,
          body: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                StaffScoreGauge(score: score),
                const SizedBox(height: 14),
                if (events.isEmpty)
                  Text(
                      'Rien à signaler ce mois-ci — la note est au maximum.',
                      style: AppTextStyles.captionHint)
                else ...[
                  const Text('Historique du mois',
                      style: AppTextStyles.label),
                  const SizedBox(height: 6),
                  // Liste bornée en hauteur : un mois chargé ne doit pas
                  // pousser les deux boutons hors de l'écran.
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 220),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: events.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 6),
                      itemBuilder: (_, i) {
                        final r = events[i];
                        final color = r.isBonus ? sem.success : sem.danger;
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: color.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                  '${r.points > 0 ? '+' : ''}${r.points}',
                                  style: AppTextStyles.micro.copyWith(
                                      color: sem.textFor(color))),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(r.reason,
                                      style: AppTextStyles.bodySm),
                                  Text(_dayLabel(r.createdAt),
                                      style: AppTextStyles.micro),
                                ],
                              ),
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              tooltip: 'Annuler',
                              onPressed: () =>
                                  Navigator.of(sheetCtx).pop('del:${r.id}'),
                              icon: const Icon(Icons.close_rounded, size: 16),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                AppPrimaryButton(
                  label: 'Retirer des points',
                  icon: Icons.thumb_down_outlined,
                  fullWidth: true,
                  onTap: () => Navigator.of(sheetCtx).pop('penalize'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(sheetCtx).pop('reward'),
                  icon: const Icon(Icons.thumb_up_outlined, size: 18),
                  label: const Text('Employé modèle : ajouter des points'),
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 44)),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (action == null || !mounted) return;

    if (action.startsWith('del:')) {
      final id = action.substring(4);
      final target = events.where((r) => r.id == id).toList();
      if (target.isEmpty) return;
      await StaffScoreService.delete(target.first);
      if (!mounted) return;
      setState(() {});
      AppSnack.success(context, 'Événement annulé, la note remonte.');
      return;
    }
    await _addPoints(m, penalize: action == 'penalize');
  }

  /// Saisie d'un événement. Le motif est OBLIGATOIRE : une note qui bouge sans
  /// raison écrite est incontestable, donc injuste — et le gérant lui-même ne
  /// s'en souviendra plus à la fin du mois.
  Future<void> _addPoints(StaffMember m, {required bool penalize}) async {
    final points = TextEditingController(text: '1');
    final reason = TextEditingController();
    final confirmed = await showAdaptiveFormSheet<bool>(
      context: context,
      builder: (sheetCtx) => AdaptiveFormFrame(
        title: penalize ? 'Retirer des points' : 'Ajouter des points',
        subtitle: m.fullName,
        icon: penalize ? Icons.thumb_down_outlined : Icons.thumb_up_outlined,
        body: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                  penalize
                      ? 'À n\'utiliser qu\'une fois la plainte VÉRIFIÉE. '
                          'La raison exacte sera conservée : c\'est elle que '
                          'vous montrerez à l\'employé.'
                      : 'Les points au-delà de 10 s\'affichent en bonus '
                          '(« 10 +2 ») et départagent le classement.',
                  style: AppTextStyles.captionHint),
              const SizedBox(height: 12),
              TextField(
                controller: points,
                keyboardType: const TextInputType.numberWithOptions(),
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                    labelText: 'Nombre de points', hintText: '1'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: reason,
                autofocus: true,
                maxLines: 2,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: 'Raison exacte *',
                  hintText: penalize
                      ? 'Plainte table 4 : attente de 40 min, fondée'
                      : 'A tenu la salle seul le soir du 14',
                ),
              ),
              const SizedBox(height: 18),
              AppPrimaryButton(
                label: 'Enregistrer',
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

    final n = int.tryParse(points.text.trim()) ?? 0;
    final why = reason.text.trim();
    if (n <= 0) {
      AppSnack.info(context, 'Indiquez un nombre de points supérieur à zéro.');
      return;
    }
    if (why.isEmpty) {
      AppSnack.info(context, 'La raison est obligatoire.');
      return;
    }
    if (penalize) {
      await StaffScoreService.penalize(member: m, points: n, reason: why);
    } else {
      await StaffScoreService.reward(member: m, points: n, reason: why);
    }
    if (!mounted) return;
    setState(() {});
    AppSnack.success(context,
        penalize ? '$n point(s) retiré(s).' : '$n point(s) ajouté(s).');
  }

  static String _monthLabel(DateTime d) {
    const months = [
      'janvier', 'février', 'mars', 'avril', 'mai', 'juin',
      'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre',
    ];
    return '${months[d.month - 1]} ${d.year}';
  }

  static String _dayLabel(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')} à '
      '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}';
}

/// Une ligne du classement.
class _RankRow extends StatelessWidget {
  final int rank;
  final StaffMember member;
  final StaffScore score;
  final VoidCallback onTap;

  const _RankRow({
    required this.rank,
    required this.member,
    required this.score,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    // Le podium : trois places distinguées, pas plus. Colorer toute la liste
    // reviendrait à ne rien distinguer du tout.
    final isPodium = rank <= 3 && !score.needsReplacement;
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
              border: Border.all(
                  color: score.needsReplacement
                      ? sem.danger.withValues(alpha: 0.45)
                      : sem.borderSubtle),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 26,
                  child: isPodium
                      ? Icon(Icons.emoji_events_rounded,
                          size: 18,
                          color: rank == 1
                              ? const Color(0xFFD4A017)
                              : cs.onSurface.withValues(alpha: 0.45))
                      : Text('$rank',
                          style: AppTextStyles.bodySmBold.copyWith(
                              color:
                                  cs.onSurface.withValues(alpha: 0.55))),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(member.fullName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.bodyBold
                              .copyWith(color: cs.onSurface)),
                      if (member.role.isNotEmpty)
                        Text(member.role,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTextStyles.caption),
                      const SizedBox(height: 6),
                      StaffScoreGauge(score: score),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
