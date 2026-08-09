import 'package:flutter/material.dart';

import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../domain/entities/ingredient.dart';

/// Sélecteur de la méthode de chiffrage d'UN ingrédient.
///
/// Groupe de deux boutons radio. L'explication de chaque méthode n'est PAS
/// affichée en permanence : elle tient en quatre lignes chacune, et deux
/// pavés de texte au-dessus d'un formulaire de six champs se sautent au lieu
/// de se lire. Elle est derrière une icône d'information, à portée de doigt de
/// qui hésite, invisible pour qui sait déjà.
class CostMethodPicker extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;

  const CostMethodPicker({
    super.key,
    required this.value,
    required this.onChanged,
  });

  static const _explanations = <String, ({String what, String note})>{
    Ingredient.costRepartition: (
      what: 'Les achats du mois se répartissent entre les plats vendus qui '
          'contiennent l\'ingrédient. Aucune quantité à peser. Le coût suit '
          'la trésorerie et varie d\'un mois à l\'autre.',
      note: 'Convient à ce qui s\'achète en tas et ne se pèse pas : piment, '
          'cubes, épices.',
    ),
    Ingredient.costSheet: (
      what: 'La quantité utilisée par portion est définie dans la fiche '
          'technique du plat. Le coût est calculé sur la quantité réelle '
          'consommée à chaque vente.',
      note: 'Nécessite de renseigner les quantités par portion dans chaque '
          'fiche recette, et la quantité achetée à la création.',
    ),
  };

  void _explain(BuildContext context, String method, String label) {
    final e = _explanations[method]!;
    showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        icon: const Icon(Icons.info_outline_rounded),
        title: Text(label, style: AppTextStyles.subtitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(e.what, style: AppTextStyles.body.copyWith(height: 1.55)),
            const SizedBox(height: 10),
            Text(e.note, style: AppTextStyles.caption),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text('Compris'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: sem.borderSubtle, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Méthode de calcul du coût matières',
              style:
                  AppTextStyles.caption.copyWith(fontWeight: FontWeight.w500)),
          const SizedBox(height: 4),
          for (final entry in const [
            (Ingredient.costRepartition, 'Répartition des achats'),
            (Ingredient.costSheet, 'Fiche technique'),
          ])
            _MethodRadio(
              label: entry.$2,
              selected: value == entry.$1,
              onSelect: () => onChanged(entry.$1),
              onInfo: () => _explain(context, entry.$1, entry.$2),
            ),
        ],
      ),
    );
  }
}

/// Une ligne du groupe : `ⓘ  ◉  libellé`.
///
/// L'icône d'information est DEVANT le bouton radio et porte sa propre zone
/// tactile : la toucher explique, elle ne sélectionne pas. Sans cette
/// séparation, on changerait de méthode en cherchant simplement à comprendre
/// laquelle choisir.
class _MethodRadio extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onInfo;

  const _MethodRadio({
    required this.label,
    required this.selected,
    required this.onSelect,
    required this.onInfo,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(children: [
      IconButton(
        onPressed: onInfo,
        tooltip: 'À quoi sert « $label » ?',
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
        padding: EdgeInsets.zero,
        icon: Icon(Icons.info_outline_rounded,
            size: 18, color: theme.colorScheme.onSurfaceVariant),
      ),
      Expanded(
        child: InkWell(
          onTap: onSelect,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: Row(children: [
              Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                  size: 20,
                  color: selected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: (selected
                            ? AppTextStyles.bodySmBold
                            : AppTextStyles.bodySm)
                        .copyWith(color: theme.colorScheme.onSurface)),
              ),
            ]),
          ),
        ),
      ),
    ]);
  }
}
