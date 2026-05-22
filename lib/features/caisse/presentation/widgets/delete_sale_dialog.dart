import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../domain/entities/sale.dart';
import '../../domain/usecases/delete_sale_usecase.dart';

/// Dialog de confirmation pour la suppression sécurisée d'une commande
/// (hotfix_084). Champ motif obligatoire + checkbox de confirmation.
///
/// Le dialog appelle [onConfirm] avec le motif quand l'utilisateur valide.
/// [onConfirm] doit lever une [DeleteSaleException] (ou autre `Exception`)
/// si la suppression échoue ; le message est alors affiché en bas du
/// dialog sans le fermer, l'utilisateur peut corriger ou annuler.
///
/// Si [onConfirm] retourne sans lever, le dialog pop avec `true`.
///
/// Ouverture : [showDeleteSaleDialog].
class DeleteSaleDialog extends StatefulWidget {
  final Sale order;
  final Future<void> Function(String reason) onConfirm;
  const DeleteSaleDialog({
    super.key,
    required this.order,
    required this.onConfirm,
  });

  @override
  State<DeleteSaleDialog> createState() => _DeleteSaleDialogState();
}

class _DeleteSaleDialogState extends State<DeleteSaleDialog> {
  late final TextEditingController _reasonCtrl;
  bool _confirmed = false;
  bool _submitting = false;
  String? _serverError;

  @override
  void initState() {
    super.initState();
    _reasonCtrl = TextEditingController();
    _reasonCtrl.addListener(() => setState(() {})); // rebuild bouton
  }

  @override
  void dispose() {
    _reasonCtrl.dispose();
    super.dispose();
  }

  bool get _isReasonValid =>
      _reasonCtrl.text.trim().length >= DeleteSaleUseCase.minReasonLength;

  bool get _canSubmit => _isReasonValid && _confirmed && !_submitting;

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() {
      _submitting = true;
      _serverError = null;
    });
    try {
      await widget.onConfirm(_reasonCtrl.text.trim());
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on DeleteSaleException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _serverError = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _serverError = 'Erreur inattendue : ${e.toString()}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final order = widget.order;
    final clientLabel = (order.clientName ?? '').isNotEmpty
        ? order.clientName!
        : 'Client non précisé';
    final itemsCount = order.items.fold<int>(0, (s, i) => s + i.quantity);
    final totalLabel = CurrencyFormatter.format(order.total);

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── En-tête ────────────────────────────────────────────────
              Row(children: [
                Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.error.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.delete_outline_rounded,
                      color: AppColors.error, size: 22),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text('Supprimer cette commande',
                      style: AppTextStyles.subtitleBold),
                ),
              ]),
              const SizedBox(height: 16),

              // ── Récap commande ─────────────────────────────────────────
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: AppColors.inputFill,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(clientLabel,
                        style: AppTextStyles.bodyBold,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 4),
                    Text(
                      '$itemsCount article${itemsCount > 1 ? "s" : ""} · '
                      '$totalLabel · ${order.status.label}',
                      style: AppTextStyles.bodySmSecondary,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              // ── Champ motif ────────────────────────────────────────────
              const Text('Motif de la suppression',
                  style: AppTextStyles.label),
              const SizedBox(height: 6),
              TextField(
                controller: _reasonCtrl,
                minLines: 2,
                maxLines: 4,
                maxLength: 240,
                enabled: !_submitting,
                style: AppTextStyles.input,
                decoration: InputDecoration(
                  hintText: 'Ex. : annulée à la demande du client après '
                      'erreur de saisie',
                  hintStyle: AppTextStyles.inputHint,
                  filled: true,
                  fillColor: AppColors.inputFill,
                  counterStyle: AppTextStyles.micro,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(
                        color: AppColors.inputBorder),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(
                        color: AppColors.inputBorder),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(
                        color: AppColors.primary, width: 1.5),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _isReasonValid
                    ? 'Motif valide.'
                    : '${DeleteSaleUseCase.minReasonLength} caractères '
                      'minimum (${_reasonCtrl.text.trim().length} '
                      'actuellement).',
                style: AppTextStyles.caption.copyWith(
                    color: _isReasonValid
                        ? AppColors.secondary
                        : AppColors.textHint),
              ),
              const SizedBox(height: 10),

              // ── Checkbox confirmation ──────────────────────────────────
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: _submitting
                    ? null
                    : () => setState(() => _confirmed = !_confirmed),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Checkbox(
                        value: _confirmed,
                        onChanged: _submitting
                            ? null
                            : (v) => setState(() => _confirmed = v ?? false),
                        activeColor: AppColors.error,
                      ),
                      const Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(top: 12),
                          child: Text(
                            'Je confirme la suppression de cette commande. '
                            'Le stock réservé sera restauré.',
                            style: AppTextStyles.bodySm,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // ── Erreur serveur ─────────────────────────────────────────
              if (_serverError != null) ...[
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.error.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: AppColors.error.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.error_outline_rounded,
                          color: AppColors.error, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _serverError!,
                          style: AppTextStyles.bodySm.copyWith(
                              color: AppColors.error),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 16),

              // ── Actions ────────────────────────────────────────────────
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _submitting
                        ? null
                        : () => Navigator.of(context).pop(false),
                    child: const Text('Annuler',
                        style: TextStyle(color: AppColors.textSecondary)),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: _canSubmit ? _submit : null,
                    icon: _submitting
                        ? const SizedBox(
                            width: 14, height: 14,
                            child: CircularProgressIndicator(
                                color: Colors.white, strokeWidth: 2))
                        : const Icon(Icons.delete_outline_rounded,
                            size: 18),
                    label: Text(_submitting ? 'Suppression…' : 'Supprimer'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.error,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor:
                          AppColors.error.withValues(alpha: 0.4),
                      disabledForegroundColor:
                          Colors.white.withValues(alpha: 0.7),
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Helper d'ouverture. Renvoie `true` si la suppression a réussi,
/// `false` ou `null` si l'utilisateur a annulé.
Future<bool?> showDeleteSaleDialog(
  BuildContext context, {
  required Sale order,
  required Future<void> Function(String reason) onConfirm,
}) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => DeleteSaleDialog(order: order, onConfirm: onConfirm),
  );
}
