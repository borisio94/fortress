import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../domain/entities/product.dart';
import '../../domain/usecases/delete_product_usecase.dart';

/// Dialog de confirmation pour la suppression sécurisée d'un produit
/// (hotfix_085). Champ motif obligatoire (min 10 caractères) + checkbox
/// de confirmation. Bouton danger désactivé tant que ces 2 conditions
/// ne sont pas réunies.
///
/// L'appel à [onConfirm] est attendu : si l'opération réussit le dialog
/// pop avec `true`. Si une [DeleteProductException] (motif, permission)
/// ou une [ProductNotDeletableException] (stock / commandes ouvertes)
/// est levée, le dialog l'affiche en place et reste ouvert pour que
/// l'utilisateur puisse corriger ou annuler.
///
/// Helper d'ouverture : [showDeleteProductDialog].
class DeleteProductDialog extends StatefulWidget {
  final Product product;
  final Future<void> Function(String reason) onConfirm;
  const DeleteProductDialog({
    super.key,
    required this.product,
    required this.onConfirm,
  });

  @override
  State<DeleteProductDialog> createState() => _DeleteProductDialogState();
}

class _DeleteProductDialogState extends State<DeleteProductDialog> {
  late final TextEditingController _reasonCtrl;
  bool _confirmed = false;
  bool _submitting = false;
  String? _serverError;

  @override
  void initState() {
    super.initState();
    _reasonCtrl = TextEditingController();
    _reasonCtrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _reasonCtrl.dispose();
    super.dispose();
  }

  bool get _isReasonValid =>
      _reasonCtrl.text.trim().length >= DeleteProductUseCase.minReasonLength;

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
    } on DeleteProductException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _serverError = e.message;
      });
    } on ProductNotDeletableException catch (e) {
      // L'exception existante (stock / commandes ouvertes) n'implémente
      // pas DeleteProductException mais expose les mêmes getters
      // `code`/`message`. On l'attrape séparément pour préserver la
      // compatibilité avec le code legacy qui la lève.
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
    final p = widget.product;
    final variantCount = p.variants.length;
    final variantLabel = variantCount == 0
        ? 'Sans variante'
        : variantCount == 1
            ? '1 variante'
            : '$variantCount variantes';
    final imageUrl = p.mainImageUrl;
    final sku = (p.sku ?? '').isNotEmpty ? p.sku! : '—';

    return AdaptiveFormFrame(
      title: 'Supprimer ce produit',
      icon: Icons.delete_outline_rounded,
      iconColor: AppColors.error,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
              // ── Récap produit : image + nom + SKU + variantes ─────────
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.inputFill,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        width: 56, height: 56,
                        child: imageUrl != null && imageUrl.isNotEmpty
                            ? Image.network(imageUrl, fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) =>
                                    const _PlaceholderImg())
                            : const _PlaceholderImg(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(p.name,
                              style: AppTextStyles.bodyBold,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis),
                          const SizedBox(height: 2),
                          Text('SKU $sku · $variantLabel',
                              style: AppTextStyles.bodySmSecondary),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Ce produit sera retiré du catalogue (POS + web). '
                'Son historique de ventes reste conservé pour audit. '
                'Un super-admin pourra le restaurer en cas d\'erreur.',
                style: AppTextStyles.bodySmSecondary,
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
                  hintText: 'Ex. : référence remplacée par le nouveau '
                      'modèle 2026',
                  hintStyle: AppTextStyles.inputHint,
                  filled: true,
                  fillColor: AppColors.inputFill,
                  counterStyle: AppTextStyles.micro,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: AppColors.inputBorder),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: AppColors.inputBorder),
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
                    : '${DeleteProductUseCase.minReasonLength} caractères '
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
                            'Je confirme la suppression de ce produit. '
                            'Il sera retiré du catalogue et masqué partout.',
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

              ],
            ),
          ),

      // ── Actions épinglées (pleine largeur, toujours visibles) ──
      footer: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _submitting
                    ? null
                    : () => Navigator.of(context).pop(false),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 48),
                  foregroundColor: AppColors.textSecondary,
                ),
                child: const Text('Annuler'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _canSubmit ? _submit : null,
                icon: _submitting
                    ? const SizedBox(
                        width: 14, height: 14,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2))
                    : const Icon(Icons.delete_outline_rounded, size: 18),
                label: Text(_submitting ? 'Suppression…' : 'Supprimer'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.error,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor:
                      AppColors.error.withValues(alpha: 0.4),
                  disabledForegroundColor:
                      Colors.white.withValues(alpha: 0.7),
                  elevation: 0,
                  minimumSize: const Size(0, 48),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlaceholderImg extends StatelessWidget {
  const _PlaceholderImg();
  @override
  Widget build(BuildContext context) => Container(
        color: Theme.of(context).semantic.borderSubtle,
        child: Icon(Icons.image_outlined,
            color: AppColors.textHint, size: 22),
      );
}

/// Helper d'ouverture. Renvoie `true` si la suppression a réussi,
/// `false` ou `null` si l'utilisateur a annulé.
Future<bool?> showDeleteProductDialog(
  BuildContext context, {
  required Product product,
  required Future<void> Function(String reason) onConfirm,
}) {
  return showAdaptiveFormSheet<bool>(
    context: context,
    builder: (_) => DeleteProductDialog(product: product, onConfirm: onConfirm),
  );
}
