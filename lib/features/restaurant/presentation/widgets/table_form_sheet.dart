import 'package:flutter/material.dart';

import '../../../../core/services/restaurant_table_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_field.dart';
import '../../../../shared/widgets/app_primary_button.dart';

/// Formulaire de création d'une table (nom + capacité).
///
/// Extrait du plan de salle, qui en est aujourd'hui le SEUL appelant : l'écran
/// de mise en route n'ouvre pas ce formulaire, il pousse vers le plan de salle.
/// Le fichier reste séparé parce que la feuille a sa propre vie, pas parce que
/// deux écrans l'ouvriraient.
///
/// ⚠ N'EFFECTUE AUCUN CONTRÔLE DE PERMISSION : c'est l'appelant qui garde le
/// geste (`canEditShopInfo`), comme partout ailleurs dans ce dépôt. Un second
/// appelant devra poser la même garde.
///
/// Retourne l'issue de l'écriture, ou `null` si la feuille a été fermée sans
/// créer. L'appelant doit la regarder avant d'annoncer quoi que ce soit : une
/// écriture locale refusée laisse la grille vide, et « Table créée » y était
/// affiché quand même.
Future<TableWriteOutcome?> showTableForm({
  required BuildContext context,
  required String shopId,
}) async {
  final nameCtrl = TextEditingController();
  final capCtrl = TextEditingController(text: '4');
  final suggested = RestaurantTableService.nextNumber(shopId);
  nameCtrl.text = 'T$suggested';

  final created = await showAdaptiveFormSheet<bool>(
    context: context,
    builder: (ctx) => AdaptiveFormFrame(
      title: 'Nouvelle table',
      subtitle: 'Table n°$suggested',
      icon: Icons.restaurant_rounded,
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // PAS D'ASTÉRISQUE. Les deux champs arrivent pré-remplis et ont
            // un repli : laissés vides, ils valent « T<n> » et 4. L'étoile
            // rouge promettait un refus qui n'arrive jamais — l'aide dit le
            // repli à sa place.
            const AppFieldLabel('Nom de la table'),
            const SizedBox(height: 8),
            AppField(
              controller: nameCtrl,
              hint: 'T$suggested',
              autofocus: true,
              prefixIcon: Icons.label_outline_rounded,
            ),
            const SizedBox(height: 6),
            Text('Laissé vide, le nom sera « T$suggested ».',
                style: AppTextStyles.caption),
            const SizedBox(height: 16),
            const AppFieldLabel('Capacité (couverts)'),
            const SizedBox(height: 8),
            AppField(
              controller: capCtrl,
              hint: '4',
              numbersOnly: true,
              keyboardType: TextInputType.number,
              prefixIcon: Icons.people_outline_rounded,
            ),
            const SizedBox(height: 6),
            Text('Laissée vide, elle sera de 4 couverts.',
                style: AppTextStyles.caption),
            const SizedBox(height: 20),
            AppPrimaryButton(
              label: 'Créer la table',
              icon: Icons.add_rounded,
              fullWidth: true,
              onTap: () => Navigator.of(ctx).pop(true),
            ),
          ],
        ),
      ),
    ),
  );

  if (created != true) {
    nameCtrl.dispose();
    capCtrl.dispose();
    return null;
  }

  final name = nameCtrl.text.trim();
  // Capacité bornée : une saisie vide ou absurde retombe sur 4 plutôt que de
  // créer une table à 0 place (rendrait le sélecteur de couverts inerte).
  final capacity = (int.tryParse(capCtrl.text.trim()) ?? 4).clamp(1, 99);
  nameCtrl.dispose();
  capCtrl.dispose();

  final result = await RestaurantTableService.addTable(
    shopId: shopId,
    name: name.isEmpty ? 'T$suggested' : name,
    capacity: capacity,
  );
  return result.outcome;
}
