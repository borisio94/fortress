import 'package:flutter/material.dart';

import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../domain/entities/ingredient.dart';

/// Sélecteur de la méthode de chiffrage d'UN ingrédient.
///
/// TROIS RÈGLES, posées le 22/09/2026 après avoir vu le résultat des
/// précédentes.
///
/// LE LIBELLÉ NOMME L'USAGE, PAS LA COMPTABILITÉ. « Répartition des achats »
/// et « Fiche technique » décrivaient le calcul, qui n'est pas la question
/// que se pose le restaurateur. « Sans peser » et « Quantité connue »
/// décrivent ce qu'il fait dans sa cuisine, et il sait lequel est le sien.
///
/// LES EXEMPLES VIENNENT DU MÉTIER. Ndolé, poisson braisé, poulet DG d'un
/// côté ; chawarma, glace, boisson de l'autre. On se reconnaît dans une des
/// deux listes en une seconde, là où une définition demande de se traduire.
///
/// L'EXPLICATION NE SE CACHE PLUS DERRIÈRE UNE ICÔNE. Elle était dans un ⓘ,
/// au motif que deux pavés de texte au-dessus d'un formulaire se sautent au
/// lieu de se lire. C'était vrai du pavé, pas de l'icône : personne n'ouvre
/// une infobulle AVANT de choisir — on la découvre après s'être trompé. Deux
/// lignes sous chaque option, toujours visibles, remplacent deux icônes qu'on
/// ignorait.
class CostMethodPicker extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;

  const CostMethodPicker({
    super.key,
    required this.value,
    required this.onChanged,
  });

  /// Les deux choix, dans l'ordre où ils sont proposés.
  ///
  /// `label` répond à « qu'est-ce que je fais ? », `what` à « qu'est-ce que
  /// ça calcule ? », `example` à « est-ce que c'est ma cuisine ? ». C'est le
  /// troisième qui tranche le plus vite, et c'est pour ça qu'il est là.
  static const _options =
      <({String value, String label, String what, String example})>[
    (
      value: Ingredient.costRepartition,
      label: 'Sans peser',
      what: 'Vos achats du mois se répartissent sur les plats vendus. '
          'Aucune quantité par portion à saisir.',
      example: 'Ndolé, poisson braisé, poulet DG — ce qui mijote en marmite '
          'et se sert à la louche.',
    ),
    (
      value: Ingredient.costSheet,
      label: 'Quantité connue',
      what: 'Vous dites combien il en faut par portion. Le coût suit ce qui '
          'est réellement consommé, vente par vente.',
      example: 'Chawarma, glace, boisson — ce qui se compte à l\'unité ou se '
          'dose au gramme.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: sem.borderSubtle, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // La question, pas le nom du calcul. « Méthode de calcul du coût
          // matières » annonçait un chapitre de comptabilité au-dessus de
          // deux cases à cocher.
          Text('Comment chiffrer cet ingrédient ?',
              style:
                  AppTextStyles.caption.copyWith(fontWeight: FontWeight.w500)),
          const SizedBox(height: 4),
          for (final o in _options)
            _MethodRadio(
              label: o.label,
              what: o.what,
              example: o.example,
              selected: value == o.value,
              onSelect: () => onChanged(o.value),
            ),
        ],
      ),
    );
  }
}

/// Une ligne du groupe : `◉  libellé` + ce que ça veut dire + un exemple.
///
/// PLUS D'ICÔNE D'INFORMATION. Elle était devant le bouton radio, avec sa
/// propre zone tactile, pour qu'on puisse comprendre sans sélectionner. Le
/// raisonnement tenait, mais il supposait qu'on la touche — or on ne cherche
/// pas à comprendre un choix qu'on croit avoir compris. L'explication est
/// maintenant sous le libellé, où elle se lit sans rien demander.
class _MethodRadio extends StatelessWidget {
  final String label;
  final String what;
  final String example;
  final bool selected;
  final VoidCallback onSelect;

  const _MethodRadio({
    required this.label,
    required this.what,
    required this.example,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onSelect,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: (selected
                              ? AppTextStyles.bodySmBold
                              : AppTextStyles.bodySm)
                          .copyWith(color: theme.colorScheme.onSurface)),
                  const SizedBox(height: 2),
                  Text(what, style: AppTextStyles.caption),
                  const SizedBox(height: 1),
                  Text(example, style: AppTextStyles.captionHint),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
