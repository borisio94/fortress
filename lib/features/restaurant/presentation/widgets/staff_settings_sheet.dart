import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;

import '../../../../core/database/app_database.dart';
import '../../../../core/services/staff_service.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../hr/domain/models/job_titles.dart';
import '../../domain/entities/shift_evaluation.dart';

/// RÉGLAGES DU PERSONNEL — l'horaire et le prix d'une heure en plus.
///
/// Deux réglages seulement, mais ce sont eux qui rendent tout le reste
/// possible : sans heure de fermeture, aucun départ n'est ni anticipé ni
/// supplémentaire ; sans taux, une heure supplémentaire se compte en minutes
/// et se paie zéro franc.
///
/// C'est pourquoi cet écran dit ce qui se passe quand on ne règle RIEN, plutôt
/// que de laisser croire à une panne : un restaurant qui n'a pas d'horaire fixe
/// a le droit de continuer comme avant.
Future<void> showStaffSettingsSheet(
    BuildContext context, String shopId) async {
  await showAdaptiveFormSheet<void>(
    context: context,
    builder: (_) => _StaffSettingsSheet(shopId: shopId),
  );
}

class _StaffSettingsSheet extends StatefulWidget {
  final String shopId;
  const _StaffSettingsSheet({required this.shopId});

  @override
  State<_StaffSettingsSheet> createState() => _StaffSettingsSheetState();
}

class _StaffSettingsSheetState extends State<_StaffSettingsSheet> {
  late String? _closing = LocalStorageService.getShopClosingTime(widget.shopId);

  /// Un contrôleur par poste. Les postes viennent de la liste déclarée par la
  /// boutique ET des fonctions réellement portées par le personnel : un poste
  /// supprimé de la liste mais encore porté par quelqu'un doit garder son
  /// taux, sinon les heures supplémentaires de cette personne tomberaient à
  /// zéro sans que personne ne l'ait décidé.
  late final Map<String, TextEditingController> _rates = {
    for (final title in JobTitles.merge(
      LocalStorageService.getJobTitles(widget.shopId),
      [for (final s in StaffService.forShop(widget.shopId)) s.role],
    ))
      title: TextEditingController(
        text: (_savedRate(title) == 0) ? '' : '${_savedRate(title)}',
      ),
  };

  int _savedRate(String title) {
    for (final e
        in LocalStorageService.getJobTitleRates(widget.shopId).entries) {
      if (JobTitles.same(e.key, title)) return e.value;
    }
    return 0;
  }

  @override
  void dispose() {
    for (final c in _rates.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickClosing() async {
    final parsed = ShiftEvaluation.parseHhmm(_closing);
    final picked = await showTimePicker(
      context: context,
      initialTime: parsed == null
          ? const TimeOfDay(hour: 22, minute: 0)
          : TimeOfDay(hour: parsed.$1, minute: parsed.$2),
      helpText: 'Heure de fin de service',
    );
    if (picked == null) return;
    setState(() =>
        _closing = ShiftEvaluation.formatHhmm(picked.hour, picked.minute));
  }

  Future<void> _save() async {
    await AppDatabase.setShopClosingTime(widget.shopId, _closing);
    for (final e in _rates.entries) {
      final v = int.tryParse(e.value.text.trim()) ?? 0;
      // Écrit même à zéro : c'est ainsi qu'on RETIRE un taux devenu obsolète.
      if (v != _savedRate(e.key)) {
        await AppDatabase.saveJobTitle(widget.shopId, e.key, overtimeRate: v);
      }
    }
    if (!mounted) return;
    Navigator.of(context).pop();
    AppSnack.success(context, 'Réglages enregistrés.');
  }

  @override
  Widget build(BuildContext context) {
    return AdaptiveFormFrame(
      title: 'Réglages du personnel',
      icon: Icons.tune_rounded,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Heure de fin de service',
                style: AppTextStyles.label),
            const SizedBox(height: 2),
            Text(
                'La référence de tous les pointages : partir avant appelle une '
                'excuse, rester après crée des heures supplémentaires. Une '
                'tolérance de ${ShiftEvaluation.graceMinutes} minutes '
                's\'applique de part et d\'autre.',
                style: AppTextStyles.captionHint),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: InkWell(
                  onTap: _pickClosing,
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Fermeture',
                      suffixIcon: Icon(Icons.schedule_rounded, size: 18),
                    ),
                    child: Text(_closing ?? 'Non réglée',
                        style: AppTextStyles.body),
                  ),
                ),
              ),
              if (_closing != null) ...[
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => setState(() => _closing = null),
                  child: const Text('Retirer'),
                ),
              ],
            ]),
            if (_closing == null) ...[
              const SizedBox(height: 4),
              Text(
                  'Sans horaire, aucun départ n\'est jugé et aucune heure '
                  'supplémentaire n\'est comptée — le pointage fonctionne '
                  'comme avant.',
                  style: AppTextStyles.captionHint),
            ],
            const Divider(height: 26),
            const Text('Taux horaire des heures supplémentaires',
                style: AppTextStyles.label),
            const SizedBox(height: 2),
            Text(
                'Par fonction, en francs pour UNE heure. Les minutes sont '
                'payées au prorata. Une fonction laissée vide compte les '
                'heures mais ne les valorise pas.',
                style: AppTextStyles.captionHint),
            const SizedBox(height: 10),
            if (_rates.isEmpty)
              Text(
                  'Aucune fonction déclarée. Créez-les dans « Accès à l\'app » '
                  'ou sur les fiches du personnel.',
                  style: AppTextStyles.captionHint)
            else
              // Bornée en hauteur : douze fonctions ne doivent pas repousser le
              // bouton d'enregistrement hors de l'écran.
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final e in _rates.entries)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(children: [
                          Expanded(
                            child: Text(e.key, style: AppTextStyles.bodySm),
                          ),
                          SizedBox(
                            width: 120,
                            child: TextField(
                              controller: e.value,
                              textAlign: TextAlign.end,
                              keyboardType:
                                  const TextInputType.numberWithOptions(),
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly
                              ],
                              decoration: InputDecoration(
                                isDense: true,
                                hintText: '0',
                                suffixText: CurrencyFormatter.currentSymbol,
                              ),
                            ),
                          ),
                        ]),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 18),
            AppPrimaryButton(
              label: 'Enregistrer',
              icon: Icons.check_rounded,
              fullWidth: true,
              onTap: _save,
            ),
          ],
        ),
      ),
    );
  }
}
