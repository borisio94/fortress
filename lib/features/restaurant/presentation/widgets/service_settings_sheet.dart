import 'package:flutter/material.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../shop_selector/domain/entities/shop_summary.dart';

/// RÉGLAGES DU SERVICE — les seuils de retard (hotfix_183, 25/09/2026).
///
/// Ouverte depuis l'écran COMMANDES, là où le retard se voit : un gérant qui
/// trouve « 24 min en retard » trop sévère doit pouvoir le changer sans
/// chercher dans quel écran ça vit. Pas dans les « Réglages du personnel » :
/// ceux-là jugent des horaires de TRAVAIL, pas la cadence du service — deux
/// sujets qui se ressemblent et n'ont rien à voir.
///
/// RÉSERVÉE À L'ADMIN, et l'ENTRÉE elle-même est masquée pour les autres
/// (cf. l'appel dans `caisse_page.dart`) : une porte fermée qu'on voit est une
/// frustration.
///
/// Les valeurs vivent dans `shops` (partagées par tous les appareils), pas
/// dans `ShopSettingsStore` : un seuil doit être le même sur le téléphone du
/// serveur et celui du gérant. L'écriture passe par `AppDatabase.updateShop`
/// — EN LIGNE, comme les autres réglages de la boutique.
Future<void> showServiceSettingsSheet(
    BuildContext context, String shopId) async {
  await showAdaptiveFormSheet<void>(
    context: context,
    builder: (_) => _ServiceSettingsSheet(shopId: shopId),
  );
}

/// Bornes d'un seuil — les mêmes que `updateShop` et le CHECK de hotfix_183.
const int _kMin = 1;
const int _kMax = 240;

class _ServiceSettingsSheet extends StatefulWidget {
  final String shopId;
  const _ServiceSettingsSheet({required this.shopId});

  @override
  State<_ServiceSettingsSheet> createState() => _ServiceSettingsSheetState();
}

class _ServiceSettingsSheetState extends State<_ServiceSettingsSheet> {
  late final ShopSummary? _shop = LocalStorageService.getShop(widget.shopId);
  late int _send = _shop?.serviceLateSendMin ?? kServiceLateSendDefault;
  late int _kitchen =
      _shop?.serviceLateKitchenMin ?? kServiceLateKitchenDefault;
  late int _pass = _shop?.serviceLatePassMin ?? kServiceLatePassDefault;
  bool _saving = false;

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await AppDatabase.updateShop(
        shopId: widget.shopId,
        serviceLateSendMin: _send,
        serviceLateKitchenMin: _kitchen,
        serviceLatePassMin: _pass,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      AppSnack.success(context, 'Réglages du service enregistrés.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      // Réglage de la boutique : il s'écrit EN LIGNE. Hors connexion, on le
      // dit plutôt que de laisser croire qu'il a été retenu.
      AppSnack.error(context,
          'Impossible d\'enregistrer — vérifiez la connexion et réessayez.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AdaptiveFormFrame(
      title: 'Réglages du service',
      icon: Icons.timer_outlined,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Retards du service', style: AppTextStyles.label),
            const SizedBox(height: 2),
            Text(
                'Le temps au-delà duquel une commande est signalée en retard '
                'sur l\'écran Commandes. Il se compte depuis son ENTRÉE dans '
                'l\'état — pas depuis sa création.',
                style: AppTextStyles.bodySmSecondary),
            const SizedBox(height: 16),
            _ThresholdRow(
              label: 'À envoyer',
              effect: 'Au-delà, une commande que personne n\'a prise en '
                  'charge est signalée en retard sur l\'écran Commandes.',
              minutes: _send,
              onChanged: (v) => setState(() => _send = v),
            ),
            const SizedBox(height: 14),
            _ThresholdRow(
              label: 'En préparation',
              effect: 'Au-delà, la commande est signalée en retard sur '
                  'l\'écran Commandes : la cuisine tarde.',
              minutes: _kitchen,
              onChanged: (v) => setState(() => _kitchen = v),
            ),
            const SizedBox(height: 14),
            _ThresholdRow(
              label: 'À servir',
              effect: 'Au-delà, la commande est signalée en retard sur '
                  'l\'écran Commandes : le plat attend au passe et refroidit.',
              minutes: _pass,
              onChanged: (v) => setState(() => _pass = v),
            ),
            const SizedBox(height: 20),
            AppPrimaryButton(
              label: 'Enregistrer',
              icon: Icons.check_rounded,
              fullWidth: true,
              isLoading: _saving,
              // `isLoading` neutralise déjà le bouton pendant l'écriture.
              onTap: _save,
            ),
          ],
        ),
      ),
    );
  }
}

/// Une ligne de réglage : l'état et sa valeur, puis CE QU'ELLE DÉCLENCHE —
/// un gérant qui voit « 20 » sans contexte ne saurait pas ce qu'il règle.
class _ThresholdRow extends StatelessWidget {
  final String label;
  final String effect;
  final int minutes;
  final ValueChanged<int> onChanged;

  const _ThresholdRow({
    required this.label,
    required this.effect,
    required this.minutes,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          Expanded(
            child: Text('$label · $minutes min',
                style: AppTextStyles.bodyBold.copyWith(color: cs.onSurface)),
          ),
          IconButton(
            tooltip: 'Moins une minute',
            onPressed: minutes > _kMin ? () => onChanged(minutes - 1) : null,
            icon: const Icon(Icons.remove_circle_outline_rounded, size: 20),
          ),
          IconButton(
            tooltip: 'Plus une minute',
            onPressed: minutes < _kMax ? () => onChanged(minutes + 1) : null,
            icon: const Icon(Icons.add_circle_outline_rounded, size: 20),
          ),
        ]),
        Text(effect,
            style: AppTextStyles.caption
                .copyWith(color: AppColors.textSecondary)),
      ],
    );
  }
}
