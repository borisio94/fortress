import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../domain/entities/sale.dart';

// ═════════════════════════════════════════════════════════════════════════════
// AddOrderExpenseDialog — saisie d'une dépense additionnelle sur une commande
// déjà finalisée et entièrement payée par le client. La dépense est traitée
// comme une dette envers le partenaire-livreur (entrée `deliveryOwed`
// négative dans le partner_ledger). Compensée automatiquement au prochain
// encaissement du partenaire via le solde signé du ledger.
//
// Validation :
//   • montant > 0 (pas de dépense nulle)
//   • motif non vide (traçabilité)
//
// Retour : `_OrderExpenseResult` ou null si annulé.
// ═════════════════════════════════════════════════════════════════════════════

class OrderExpenseResult {
  final double amount;
  final String label;
  const OrderExpenseResult({required this.amount, required this.label});
}

class AddOrderExpenseDialog extends StatefulWidget {
  final Sale order;
  const AddOrderExpenseDialog({super.key, required this.order});

  /// Helper d'ouverture. Retourne null si annulé.
  static Future<OrderExpenseResult?> show(BuildContext context, Sale order) {
    return showDialog<OrderExpenseResult>(
      context: context,
      builder: (_) => AddOrderExpenseDialog(order: order),
    );
  }

  @override
  State<AddOrderExpenseDialog> createState() => _AddOrderExpenseDialogState();
}

class _AddOrderExpenseDialogState extends State<AddOrderExpenseDialog> {
  final _amountCtrl = TextEditingController();
  final _labelCtrl  = TextEditingController();
  final _focus      = FocusNode();
  String? _error;

  @override
  void initState() {
    super.initState();
    // Suggestion : on pré-remplit le label avec un motif générique pour
    // accélérer la saisie. L'opérateur peut l'écraser.
    _labelCtrl.text = 'Frais supplémentaires';
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _labelCtrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _validate() {
    final raw = _amountCtrl.text.trim();
    final value = double.tryParse(raw.replaceAll(',', '.'));
    if (value == null || value <= 0) {
      setState(() => _error = 'Montant invalide');
      return;
    }
    final label = _labelCtrl.text.trim();
    if (label.isEmpty) {
      setState(() => _error = 'Motif requis');
      return;
    }
    Navigator.of(context).pop(OrderExpenseResult(
      amount: value, label: label));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fmt = NumberFormat('#,###', 'fr_FR');
    final sym = CurrencyFormatter.currentSymbol;
    return AlertDialog(
      backgroundColor: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: Row(children: [
        Icon(Icons.attach_money_rounded,
            size: 20, color: AppColors.warning),
        const SizedBox(width: 10),
        Expanded(
          child: Text('Ajouter une dépense',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: theme.colorScheme.onSurface)),
        ),
      ]),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Bandeau explicatif : la dépense devient une dette envers le
          // partenaire-livreur. Le ledger compensera automatiquement au
          // prochain encaissement de ce partenaire.
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.warning.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: AppColors.warning.withValues(alpha: 0.25)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline_rounded,
                    size: 14, color: AppColors.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                      'Ce montant sera enregistré comme dette envers le '
                      'partenaire et déduit automatiquement de son '
                      'prochain versement.',
                      style: TextStyle(
                          fontSize: 11,
                          height: 1.4,
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.8))),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Text('Total commande : ${fmt.format(widget.order.total)} $sym',
              style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurface
                      .withValues(alpha: 0.7))),
          const SizedBox(height: 14),
          // Montant
          Text('Montant de la dépense',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                  color: theme.colorScheme.onSurface
                      .withValues(alpha: 0.6))),
          const SizedBox(height: 6),
          TextField(
            controller: _amountCtrl,
            focusNode: _focus,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
            ],
            decoration: InputDecoration(
              hintText: '0',
              suffixText: sym,
              isDense: true,
              filled: true,
              fillColor: const Color(0xFFF9FAFB),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide:
                      BorderSide(color: AppColors.warning, width: 1.5)),
            ),
            style: const TextStyle(
                fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          // Motif
          Text('Motif',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                  color: theme.colorScheme.onSurface
                      .withValues(alpha: 0.6))),
          const SizedBox(height: 6),
          TextField(
            controller: _labelCtrl,
            decoration: InputDecoration(
              hintText: 'Ex : carburant, péage, dépassement frais…',
              isDense: true,
              filled: true,
              fillColor: const Color(0xFFF9FAFB),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide:
                      BorderSide(color: AppColors.primary, width: 1.5)),
            ),
            style: const TextStyle(fontSize: 13),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!,
                style: TextStyle(
                    fontSize: 11, color: theme.colorScheme.error)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('Annuler',
              style: TextStyle(
                  color: theme.colorScheme.onSurface
                      .withValues(alpha: 0.6))),
        ),
        ElevatedButton(
          onPressed: _validate,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.warning,
            foregroundColor: Colors.white,
            elevation: 0,
            padding: const EdgeInsets.symmetric(
                horizontal: 18, vertical: 10),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8)),
          ),
          child: const Text('Enregistrer en dette',
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }
}
