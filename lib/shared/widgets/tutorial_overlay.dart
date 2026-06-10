import 'package:flutter/material.dart';

import '../../core/models/tutorial_step.dart';
import '../../core/services/tutorial_service.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/theme/app_theme.dart';

/// Lance un tutoriel guidé en MODAL (carte pas-à-pas — option A).
///
/// Affiche les [steps] une par une avec « Suivant »/« Passer » et un
/// indicateur de progression. Marque le tutoriel [tutorialKey] comme « vu »
/// à la fermeture (que l'utilisateur termine OU passe).
Future<void> showGuidedTutorial(
  BuildContext context, {
  required String tutorialKey,
  required List<TutorialStep> steps,
}) async {
  if (steps.isEmpty) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierColor: Colors.black.withValues(alpha: 0.62),
    builder: (_) => _TutorialDialog(steps: steps),
  );
  await TutorialService.markSeen(tutorialKey);
}

class _TutorialDialog extends StatefulWidget {
  final List<TutorialStep> steps;
  const _TutorialDialog({required this.steps});
  @override
  State<_TutorialDialog> createState() => _TutorialDialogState();
}

class _TutorialDialogState extends State<_TutorialDialog> {
  int _i = 0;

  void _next() {
    if (_i >= widget.steps.length - 1) {
      Navigator.of(context).pop();
    } else {
      setState(() => _i++);
    }
  }

  void _skip() => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final step  = widget.steps[_i];
    final total = widget.steps.length;
    final isLast = _i == total - 1;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      // Animation slide-in (300ms) depuis le bas + fondu.
      child: TweenAnimationBuilder<double>(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        tween: Tween(begin: 0, end: 1),
        builder: (_, t, child) => Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * 24),
            child: child,
          ),
        ),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 380),
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── En-tête : icône + « Étape X / Y » + fermer (= Passer) ──
              Row(children: [
                Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.primarySurface,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(step.icon, size: 20, color: AppColors.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text('Étape ${_i + 1} / $total',
                      style: AppTextStyles.captionBold
                          .copyWith(color: AppColors.primary)),
                ),
                IconButton(
                  onPressed: _skip,
                  icon: const Icon(Icons.close_rounded, size: 20),
                  color: AppColors.textSecondary,
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                  tooltip: 'Passer',
                ),
              ]),
              const SizedBox(height: 14),
              // ── Contenu animé entre étapes ──
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                child: Column(
                  key: ValueKey(_i),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(step.title, style: AppTextStyles.subtitleBold),
                    const SizedBox(height: 6),
                    Text(step.description, style: AppTextStyles.bodySecondary),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: (_i + 1) / total,
                  minHeight: 4,
                  backgroundColor: theme.semantic.trackMuted,
                  valueColor:
                      AlwaysStoppedAnimation<Color>(AppColors.primary),
                ),
              ),
              const SizedBox(height: 12),
              // ── Actions ──
              Row(children: [
                TextButton(
                  onPressed: _skip,
                  style: TextButton.styleFrom(
                      foregroundColor: AppColors.textSecondary),
                  child: const Text('Passer'),
                ),
                const Spacer(),
                ElevatedButton(
                  onPressed: _next,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    minimumSize: const Size(124, 44),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  child: Text(isLast ? 'Terminer' : 'Suivant'),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}
