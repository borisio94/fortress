import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;

import '../../../../core/services/bottle_deposit_service.dart';
import '../../../../core/services/restaurant_order_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../features/caisse/domain/entities/sale.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../domain/entities/bottle_deposit.dart';

/// Saisie d'une consigne d'emballages, puis enregistrement.
///
/// Deux écritures indissociables, faites ici pour qu'aucun appelant ne puisse
/// n'en faire qu'une :
///   1. une ligne de FRAIS sur la commande — la caution s'ajoute au total et
///      part donc à l'encaissement ;
///   2. une ligne de SUIVI dans `bottle_deposits` — elle survivra à l'addition,
///      puisque le client rapportera les bouteilles bien après avoir payé.
///
/// [order] `null` (dépôt direct au comptoir, hors commande) → seule la seconde
/// écriture a lieu : il n'y a pas d'addition sur laquelle facturer.
///
/// Retourne la consigne créée, ou `null` si l'utilisateur renonce.
Future<BottleDeposit?> showDepositSheet({
  required BuildContext context,
  required String shopId,
  Sale? order,
  String? holder,
}) async {
  final input = await showAdaptiveFormSheet<_DepositInput>(
    context: context,
    builder: (_) => _DepositSheet(holder: holder),
  );
  if (input == null) return null;

  final deposit = await BottleDepositService.record(
    shopId: shopId,
    orderId: order?.id,
    label: input.label,
    quantity: input.quantity,
    depositPerUnit: input.depositPerUnit,
    holder: holder,
  );
  if (order != null && deposit.totalAmount > 0) {
    await RestaurantOrderService.addFee(
      order,
      label: 'Consigne · ${input.label} ×${input.quantity}',
      amount: deposit.totalAmount.toDouble(),
    );
  }
  return deposit;
}

class _DepositInput {
  final String label;
  final int quantity;
  final int depositPerUnit;
  const _DepositInput(this.label, this.quantity, this.depositPerUnit);
}

class _DepositSheet extends StatefulWidget {
  final String? holder;
  const _DepositSheet({this.holder});

  @override
  State<_DepositSheet> createState() => _DepositSheetState();
}

class _DepositSheetState extends State<_DepositSheet> {
  final _label = TextEditingController(text: 'Bouteille 65 cl');
  final _qty = TextEditingController(text: '1');
  final _unit = TextEditingController();
  String? _err;

  @override
  void dispose() {
    _label.dispose();
    _qty.dispose();
    _unit.dispose();
    super.dispose();
  }

  int get _quantity => int.tryParse(_qty.text.trim()) ?? 0;
  int get _perUnit => int.tryParse(_unit.text.trim()) ?? 0;

  void _submit() {
    if (_quantity <= 0) {
      setState(() => _err = 'Quantité invalide');
      return;
    }
    if (_perUnit <= 0) {
      setState(() => _err = 'Montant de la consigne invalide');
      return;
    }
    Navigator.of(context).pop(_DepositInput(
      _label.text.trim().isEmpty ? 'Consigne' : _label.text.trim(),
      _quantity,
      _perUnit,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    final cs = Theme.of(context).colorScheme;
    final total = _quantity * _perUnit;

    return AdaptiveFormFrame(
      title: 'Consigne d\'emballages',
      subtitle: widget.holder,
      icon: Icons.liquor_outlined,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'La caution est ajoutée à l\'addition et rendue au client quand '
              'il rapporte les emballages.',
              style: AppTextStyles.captionHint,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _label,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Emballage',
                hintText: 'Bouteille 65 cl, casier 12…',
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _qty,
                    keyboardType: const TextInputType.numberWithOptions(),
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onChanged: (_) => setState(() => _err = null),
                    decoration: const InputDecoration(labelText: 'Quantité'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _unit,
                    autofocus: true,
                    keyboardType: const TextInputType.numberWithOptions(),
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onChanged: (_) => setState(() => _err = null),
                    decoration:
                        const InputDecoration(labelText: 'Caution / unité'),
                    onSubmitted: (_) => _submit(),
                  ),
                ),
              ],
            ),
            if (total > 0) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                      child: Text('Total consigné',
                          style: AppTextStyles.captionHint)),
                  Text(CurrencyFormatter.format(total.toDouble()),
                      style:
                          AppTextStyles.subtitleBold.copyWith(color: cs.primary)),
                ],
              ),
            ],
            if (_err != null) ...[
              const SizedBox(height: 8),
              Text(_err!,
                  style: AppTextStyles.caption.copyWith(color: sem.danger)),
            ],
            const SizedBox(height: 18),
            AppPrimaryButton(
              label: 'Enregistrer la consigne',
              icon: Icons.check_rounded,
              fullWidth: true,
              onTap: _submit,
            ),
          ],
        ),
      ),
    );
  }
}
