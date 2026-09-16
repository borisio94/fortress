import 'package:flutter/material.dart';

import '../../../../core/services/restaurant_table_service.dart';
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
/// Retourne `true` si une table a été créée.
Future<bool> showTableForm({
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
            const AppFieldLabel('Nom de la table', required: true),
            const SizedBox(height: 8),
            AppField(
              controller: nameCtrl,
              hint: 'T$suggested',
              autofocus: true,
              prefixIcon: Icons.label_outline_rounded,
            ),
            const SizedBox(height: 16),
            const AppFieldLabel('Capacité (couverts)', required: true),
            const SizedBox(height: 8),
            AppField(
              controller: capCtrl,
              hint: '4',
              numbersOnly: true,
              keyboardType: TextInputType.number,
              prefixIcon: Icons.people_outline_rounded,
            ),
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
    return false;
  }

  final name = nameCtrl.text.trim();
  // Capacité bornée : une saisie vide ou absurde retombe sur 4 plutôt que de
  // créer une table à 0 place (rendrait le sélecteur de couverts inerte).
  final capacity = (int.tryParse(capCtrl.text.trim()) ?? 4).clamp(1, 99);
  nameCtrl.dispose();
  capCtrl.dispose();

  await RestaurantTableService.addTable(
    shopId: shopId,
    name: name.isEmpty ? 'T$suggested' : name,
    capacity: capacity,
  );
  return true;
}
