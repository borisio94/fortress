import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../domain/entities/sale.dart';

// ═════════════════════════════════════════════════════════════════════════════
// RecordAcompteDialog — saisie d'un acompte boutique sur une commande
// `scheduled` ou `processing`. L'opérateur tape le montant encaissé par
// la boutique avant la livraison. À la confirmation :
//   • Sale.amountPaid = amountPaid_avant + montant saisi
//   • Sale.paymentStatus = 'paid' si amountPaid_après >= total, sinon 'partial'
//
// Retourne le nouveau `amountPaid` (double) si l'utilisateur valide,
// sinon `null` (annulé). Le caller fait l'update SaleLocalDatasource.
//
// Pas d'acompte négatif possible. Pas de dépassement du total (capé).
// ═════════════════════════════════════════════════════════════════════════════

class RecordAcompteDialog extends StatefulWidget {
  final Sale order;
  const RecordAcompteDialog({super.key, required this.order});

  /// Helper : ouvre le dialog et retourne le nouveau `amountPaid` total
  /// (somme cumulée). Null si annulé.
  static Future<double?> show(BuildContext context, Sale order) {
    return showDialog<double>(
      context: context,
      builder: (_) => RecordAcompteDialog(order: order),
    );
  }

  @override
  State<RecordAcompteDialog> createState() => _RecordAcompteDialogState();
}

class _RecordAcompteDialogState extends State<RecordAcompteDialog> {
  final _amountCtrl = TextEditingController();
  final _focus      = FocusNode();
  String? _error;

  late final double _total;
  late final double _paidBefore;
  late final double _due;

  @override
  void initState() {
    super.initState();
    _total      = widget.order.total;
    _paidBefore = widget.order.amountPaid;
    _due        = (_total - _paidBefore).clamp(0, double.infinity);
    // Pré-remplir avec le solde (cas le plus fréquent : le client paie
    // tout d'un coup au moment de la livraison ou au comptoir).
    if (_due > 0) {
      _amountCtrl.text = _due.toStringAsFixed(0);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
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
    if (value > _due) {
      setState(() => _error = 'Maximum ${CurrencyFormatter.format(_due)} '
          '(montant déjà payé déduit)');
      return;
    }
    final newAmountPaid = (_paidBefore + value).clamp(0, _total);
    Navigator.of(context).pop(newAmountPaid.toDouble());
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
        Icon(Icons.payments_outlined,
            size: 20, color: AppColors.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Text('Enregistrer un acompte',
              style: AppTextStyles.subtitleBold.copyWith(
                  fontWeight: FontWeight.w800,
                  color: theme.colorScheme.onSurface)),
        ),
      ]),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Récap montants
          _row(theme, 'Total commande',
              '${fmt.format(_total)} $sym',
              bold: true),
          if (_paidBefore > 0)
            _row(theme, 'Déjà encaissé',
                '${fmt.format(_paidBefore)} $sym'),
          _row(theme, 'Reste à payer',
              '${fmt.format(_due)} $sym',
              color: AppColors.warning, bold: true),
          const Divider(height: 24),
          // Champ montant
          Text('Montant encaissé maintenant',
              style: AppTextStyles.captionBold.copyWith(
                  letterSpacing: 0.5,
                  color: theme.colorScheme.onSurface
                      .withValues(alpha: 0.6))),
          const SizedBox(height: 6),
          TextField(
            controller: _amountCtrl,
            focusNode: _focus,
            keyboardType: const TextInputType.numberWithOptions(
                decimal: true, signed: false),
            inputFormatters: [
              FilteringTextInputFormatter.allow(
                  RegExp(r'[0-9.,]')),
            ],
            onSubmitted: (_) => _validate(),
            decoration: InputDecoration(
              hintText: '0',
              suffixText: sym,
              isDense: true,
              filled: true,
              fillColor: const Color(0xFFF9FAFB),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide:
                      const BorderSide(color: Color(0xFFE5E7EB))),
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide:
                      const BorderSide(color: Color(0xFFE5E7EB))),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide:
                      BorderSide(color: AppColors.primary, width: 1.5)),
            ),
            style: AppTextStyles.title,
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!,
                style: AppTextStyles.captionHint
                    .copyWith(color: theme.colorScheme.error)),
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
          onPressed: _due > 0 ? _validate : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            elevation: 0,
            padding:
                const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8)),
          ),
          child: Text('Enregistrer',
              style: AppTextStyles.bodyBold
                  .copyWith(color: Colors.white)),
        ),
      ],
    );
  }

  Widget _row(ThemeData theme, String label, String value,
      {bool bold = false, Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        Expanded(
          child: Text(label,
              style: AppTextStyles.bodySm.copyWith(
                  color: theme.colorScheme.onSurface
                      .withValues(alpha: 0.7))),
        ),
        Text(value,
            style: AppTextStyles.body.copyWith(
                fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
                color: color ?? theme.colorScheme.onSurface)),
      ]),
    );
  }
}
