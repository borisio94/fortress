import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;

import '../../../../core/theme/app_text_styles.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';

// La feuille « Stock du jour » de la page Menu.
//
// Sortie de `_RestaurantMenuPageState._editCount` le 26/09/2026 (lot « classes
// géantes ») : la page vit sous `AppScaffold` et ne se monte pas en test ; la
// feuille, publique, a son banc (`test/widget/daily_count_sheet_test.dart`).
// Widget À ÉTAT, propriétaire de son contrôleur : il était créé dans la
// méthode de la page et jamais libéré.

/// Résultat de l'éditeur de stock du jour : `count == null` = illimité.
class DailyCountResult {
  final int? count;
  const DailyCountResult(this.count);
}

/// Éditeur du stock du jour d'un plat (admin) — un nombre, ou illimité.
/// Passe par le châssis de formulaire canonique (clavier natif géré).
///
/// Rend un [DailyCountResult] ; `null` si la feuille est fermée sans valider.
class DailyCountSheet extends StatefulWidget {
  /// Le plat, en sous-titre.
  final String dishName;

  /// Le stock du jour actuel, `null` = illimité (champ vide).
  final int? current;

  const DailyCountSheet({super.key, required this.dishName, this.current});

  @override
  State<DailyCountSheet> createState() => _DailyCountSheetState();
}

class _DailyCountSheetState extends State<DailyCountSheet> {
  late final _ctrl =
      TextEditingController(text: widget.current?.toString() ?? '');

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  int? _parse() {
    final t = _ctrl.text.trim();
    return t.isEmpty ? null : int.tryParse(t);
  }

  @override
  Widget build(BuildContext context) {
    return AdaptiveFormFrame(
      title: 'Stock du jour',
      subtitle: widget.dishName,
      icon: Icons.inventory_2_outlined,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Nombre de plats disponibles aujourd\'hui. Le compteur diminue '
              'à chaque commande ; à 0 le plat passe « épuisé ». Laissez vide '
              'pour un stock illimité.',
              style: AppTextStyles.caption,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _ctrl,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: 'Nombre de plats',
                hintText: 'ex. 20 (vide = illimité)',
              ),
              onSubmitted: (_) =>
                  Navigator.of(context).pop(DailyCountResult(_parse())),
            ),
            const SizedBox(height: 20),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context)
                      .pop(const DailyCountResult(null)),
                  child: const Text('Illimité'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: () =>
                      Navigator.of(context).pop(DailyCountResult(_parse())),
                  child: const Text('Enregistrer'),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}
