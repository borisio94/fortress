import 'package:flutter/material.dart';

import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_field.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../domain/entities/restaurant_table.dart';

// La feuille des COUVERTS du plan de salle.
//
// Sortie de `_RestaurantTablesPageState._askCovers` le 26/09/2026 (lot
// « classes géantes ») : la page vit sous `AppScaffold` et ne se monte pas en
// test ; la feuille, publique, a son banc
// (`test/widget/table_covers_sheet_test.dart`). Son bouton +/− l'a suivie : il
// ne servait qu'à elle.

/// Sélecteur de couverts (+/−) borné par la capacité de la table.
///
/// Sert à l'ouverture du service ET à l'ajustement en cours de repas, quand
/// des convives s'en vont : [title] et [confirmLabel] distinguent les deux.
///
/// Le bouton portait « Ouvrir la table » dans les deux cas — y compris pour
/// ajuster les couverts d'une table déjà ouverte, c'est-à-dire, depuis que
/// l'ouverture de service passe par le Menu, dans tous les cas réels.
///
/// Rend le nombre de couverts ; `null` si la feuille est fermée sans valider.
class TableCoversSheet extends StatefulWidget {
  final RestaurantTable table;
  final String? title;
  final String? confirmLabel;

  const TableCoversSheet({
    super.key,
    required this.table,
    this.title,
    this.confirmLabel,
  });

  @override
  State<TableCoversSheet> createState() => _TableCoversSheetState();
}

class _TableCoversSheetState extends State<TableCoversSheet> {
  late var _covers = widget.table.covers ?? widget.table.capacity;

  @override
  Widget build(BuildContext context) {
    final table = widget.table;
    final theme = Theme.of(context);
    return AdaptiveFormFrame(
      title: widget.title ?? 'Ouvrir ${table.name}',
      subtitle: 'Capacité ${table.capacity} personnes',
      icon: Icons.people_rounded,
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const AppFieldLabel('Nombre de couverts'),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _StepperButton(
                  icon: Icons.remove_rounded,
                  // Un service à 0 couvert n'a pas de sens.
                  onTap: _covers > 1 ? () => setState(() => _covers--) : null,
                ),
                SizedBox(
                  width: 88,
                  child: Text(
                    '$_covers',
                    textAlign: TextAlign.center,
                    style: AppTextStyles.display
                        .copyWith(color: theme.colorScheme.onSurface),
                  ),
                ),
                _StepperButton(
                  icon: Icons.add_rounded,
                  // BORNÉ À LA CAPACITÉ. Le compteur montait jusqu'à
                  // `capacity + 6` « pour les tables jointes », en
                  // affichant un avertissement — puis `updateCovers`
                  // re-clampait à la capacité, en silence. La valeur
                  // saisie était écrasée sans un mot.
                  //
                  // Les tables jointes ne sont supportées nulle part
                  // ailleurs : la prise de commande borne à la place
                  // restante, `computeSeating` plafonne, et
                  // la carte (« 4 sur 6 ») plafonne à la capacité.
                  // C'était une intention isolée, contredite par tout le
                  // reste du module.
                  onTap: _covers < table.capacity
                      ? () => setState(() => _covers++)
                      : null,
                ),
              ],
            ),
            const SizedBox(height: 20),
            AppPrimaryButton(
              label: widget.confirmLabel ?? 'Ouvrir la table',
              icon: Icons.check_rounded,
              fullWidth: true,
              onTap: () => Navigator.of(context).pop(_covers),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bouton rond +/− du sélecteur de couverts. `onTap: null` → désactivé.
class _StepperButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;

  const _StepperButton({required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = onTap != null;
    return Material(
      color: enabled
          ? theme.colorScheme.primary.withValues(alpha: 0.10)
          : theme.semantic.trackMuted,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        // 48 dp, LE MINIMUM MATERIAL. Ce bouton faisait 42 — un `Padding` de
        // 10 autour d'une icône de 22 — et c'est le plus mal visé de l'écran :
        // on l'atteint d'une main qui tient déjà un plateau, et on le répète
        // autant de fois qu'il y a de convives à la table.
        //
        // Un `SizedBox` et non un `Padding` élargi : la taille est ce qu'on
        // veut garantir, autant l'écrire. L'icône garde ses 22 — c'est la
        // ZONE qui grandit, pas le dessin, et le cercle passe de 42 à 48.
        child: SizedBox(
          width: 48,
          height: 48,
          child: Center(
            child: Icon(
              icon,
              size: 22,
              color: enabled
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurface.withValues(alpha: 0.35),
            ),
          ),
        ),
      ),
    );
  }
}
