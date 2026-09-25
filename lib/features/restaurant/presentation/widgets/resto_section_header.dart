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

  /// Action posée à DROITE du titre, sur la même ligne.
  ///
  /// Elle existe pour que le bouton de création cesse d'occuper une ligne à
  /// lui seul entre les onglets et la liste. Sur un écran large, cette ligne
  /// ne portait qu'un bouton de 160 px et huit cents de vide — et elle
  /// repoussait la première ligne de la liste d'autant.
  ///
  /// `null` = en-tête inchangé, exactement comme avant.
  final Widget? trailing;

  /// Ce que l'écran contient, déjà mis en mots par l'appelant — « 4 ingrédients
  /// · 2 fournitures ». Écrit là-bas et non ici : chaque écran compte des
  /// choses différentes, et les accorder au pluriel depuis un widget générique
  /// demanderait de lui apprendre la grammaire française.
  ///
  /// `null` : titre seul (Finances, 25/09/2026 — sa période vit dans un
  /// onglet, pas au niveau de la page : rien ne cadre l'écran entier).
  final String? subtitle;

  const RestoSectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.label.copyWith(color: cs.onSurface)),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.caption),
                ],
              ],
            ),
          ),
          // L'action à droite du titre, quand l'appelant en fournit une. Le
          // `Row` reste même sans elle : le rendu d'une colonne seule dans un
          // `Expanded` est identique à celui d'avant, et deux dispositions
          // parallèles auraient divergé au premier ajustement de marge.
          if (trailing != null) ...[
            const SizedBox(width: 12),
            trailing!,
          ],
        ],
      ),
    );
  }
}
