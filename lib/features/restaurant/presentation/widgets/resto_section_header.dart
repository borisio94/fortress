import 'package:flutter/material.dart';

import '../../../../core/theme/app_text_styles.dart';

/// EN-TÊTE D'ÉCRAN DU MODULE RESTAURANT : son nom, et ce qu'il contient —
/// compté en direct.
///
/// Extrait de `_MenuHeader` (écran Menu) le 21/09/2026, quand l'écran Stock a
/// eu besoin de la même chose. Le compte n'est pas décoratif : il dit d'un coup
/// d'œil si la zone est vide parce qu'il n'y a rien, ou vide parce qu'un filtre
/// est actif.
///
/// Échelon `label` (14) pour le titre, `caption` pour le sous-titre : l'échelle
/// typographique de l'application ne compte pas de 15, et inventer une taille
/// en dur pour un pixel d'écart casserait la règle qui tient tout le reste.
class RestoSectionHeader extends StatelessWidget {
  final String title;

  /// Ce que l'écran contient, déjà mis en mots par l'appelant — « 4 ingrédients
  /// · 2 fournitures ». Écrit là-bas et non ici : chaque écran compte des
  /// choses différentes, et les accorder au pluriel depuis un widget générique
  /// demanderait de lui apprendre la grammaire française.
  final String subtitle;

  const RestoSectionHeader({
    super.key,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: AppTextStyles.label.copyWith(color: cs.onSurface)),
          const SizedBox(height: 2),
          Text(subtitle, style: AppTextStyles.caption),
        ],
      ),
    );
  }
}
