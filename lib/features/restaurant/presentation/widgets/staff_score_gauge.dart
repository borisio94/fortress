import 'package:flutter/material.dart';

import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../domain/entities/staff_rating.dart';

/// L'OR du podium de la notation (trophée du premier) — une seule valeur,
/// partagée par la page Personnel et le tableau de bord. Couleur d'objet (un
/// trophée), pas d'état : elle ne suit pas le thème, comme les teintes de
/// données de `RestoSeriesColors`.
const Color kRestoPodiumGold = Color(0xFFD4A017);

/// LA JAUGE DE NOTATION d'un employé — page Personnel et tableau de bord.
///
/// Une barre plutôt qu'un chiffre seul : « 7 » ne dit rien, une barre aux
/// trois quarts remplie se lit d'un coup d'œil au milieu d'une liste de douze
/// personnes. La couleur porte le même message une seconde fois, pour qui
/// balaie l'écran sans lire.
///
/// Le surplus (« 10 +3 ») est écrit à côté du 10 et non intégré à la barre :
/// une barre qui dépasserait son cadre ne voudrait plus rien dire, et le
/// mérite au-delà du maximum doit rester visible — sinon féliciter quelqu'un
/// déjà à 10 n'a aucun effet et le geste cesse d'être fait.
class StaffScoreGauge extends StatelessWidget {
  final StaffScore score;

  /// Compacte : barre plus fine, pas de mention « à remplacer ». Pour les
  /// listes denses du tableau de bord.
  final bool dense;

  const StaffScoreGauge({super.key, required this.score, this.dense = false});

  /// Couleur d'une note — le même code partout dans l'application. C'est la
  /// couleur de BASE (la barre) ; la note ÉCRITE prend sa variante texte
  /// (`AppSemanticColors.textFor`).
  static Color colorOf(BuildContext context, StaffScore s) {
    final sem = Theme.of(context).semantic;
    if (s.needsReplacement) return sem.danger;
    if (s.score < 8) return sem.warning;
    return sem.success;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = colorOf(context, score);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: score.gauge,
                  minHeight: dense ? 6 : 9,
                  backgroundColor: cs.onSurface.withValues(alpha: 0.10),
                  valueColor: AlwaysStoppedAnimation<Color>(color),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text('${score.score}',
                style: (dense
                        ? AppTextStyles.bodySmBold
                        : AppTextStyles.bodyBold)
                    .copyWith(
                        color: Theme.of(context).semantic.textFor(color))),
            Text('/${StaffScore.baseScore}',
                style: AppTextStyles.micro),
            if (score.surplus > 0) ...[
              const SizedBox(width: 4),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .semantic
                      .success
                      .withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text('+${score.surplus}',
                    style: AppTextStyles.micro.copyWith(
                        color: Theme.of(context).semantic.successText)),
              ),
            ],
          ],
        ),
        if (!dense && score.needsReplacement) ...[
          const SizedBox(height: 4),
          Row(children: [
            Icon(Icons.warning_amber_rounded,
                size: 14, color: Theme.of(context).semantic.danger),
            const SizedBox(width: 4),
            Expanded(
              child: Text('À remplacer d\'urgence',
                  style: AppTextStyles.micro.copyWith(
                      color: Theme.of(context).semantic.dangerText)),
            ),
          ]),
        ],
      ],
    );
  }
}
