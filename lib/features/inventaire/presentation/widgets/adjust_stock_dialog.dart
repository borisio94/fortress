import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/services/stock_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/form_sheet.dart';
import '../../domain/entities/product.dart';

/// Bottom sheet de correction rapide du stock disponible d'une variante.
/// Calcule le delta vs `variant.stockAvailable` et délègue à
/// `StockService.adjustment` (qui logue automatiquement le mouvement et
/// propage variant + StockLevel boutique de manière cohérente).
///
/// Réutilisé depuis :
///   * la fiche produit (`_StockIndicators` → bouton "Corriger")
///   * la liste inventaire (icône crayon directe sur une variante)
class AdjustStockDialog extends StatefulWidget {
  final ProductVariant variant;
  final String shopId;
  final String productId;
  const AdjustStockDialog({
    super.key,
    required this.variant,
    required this.shopId,
    required this.productId,
  });

  @override
  State<AdjustStockDialog> createState() => _AdjustStockDialogState();
}

class _AdjustStockDialogState extends State<AdjustStockDialog> {
  late final TextEditingController _stockCtrl;
  late final TextEditingController _notesCtrl;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _stockCtrl = TextEditingController(
        text: widget.variant.stockAvailable.toString());
    // GF-7 : raison désormais obligatoire — on laisse le champ VIDE pour
    // forcer l'utilisateur à saisir un motif explicite et éviter le copier
    // automatique d'une raison générique non réfléchie.
    _notesCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _stockCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  int? get _parsed => int.tryParse(_stockCtrl.text.trim());
  int get _current => widget.variant.stockAvailable;
  int? get _delta => _parsed == null ? null : _parsed! - _current;

  Future<void> _submit() async {
    final parsed = _parsed;
    if (parsed == null || parsed < 0) {
      setState(() => _error = 'Saisis un nombre valide (≥ 0)');
      return;
    }
    if (parsed == _current) {
      Navigator.of(context).pop(false);
      return;
    }
    // GF-7 : validation Flutter de la raison AVANT toute écriture.
    final reason = _notesCtrl.text.trim();
    if (reason.isEmpty) {
      setState(() => _error = 'Indique une raison pour cet ajustement.');
      return;
    }
    setState(() { _submitting = true; _error = null; });
    try {
      final ok = await StockService.adjustment(
        shopId:    widget.shopId,
        productId: widget.productId,
        variantId: widget.variant.id ?? '',
        delta:     parsed - _current,
        reason:    reason,
      );
      if (!mounted) return;
      if (!ok) {
        setState(() {
          _submitting = false;
          _error = 'Impossible d\'appliquer cette correction (stock négatif ?)';
        });
        return;
      }
      Navigator.of(context).pop(true);
    } on AdjustmentReasonRequiredException catch (e) {
      // Filet de sécurité : ne devrait pas se déclencher (déjà validé
      // ci-dessus) — au cas où.
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _delta;
    return AdaptiveFormFrame(
      title: 'Corriger le stock',
      icon: Icons.edit_note_rounded,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Variante : ${widget.variant.name}',
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary)),
                const SizedBox(height: 2),
                Text('Stock disponible actuel : $_current',
                    style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.textSecondary)),
                const SizedBox(height: 14),
                const Text('Nouvelle valeur',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: AppColors.textSecondary)),
                const SizedBox(height: 4),
                TextField(
                  controller: _stockCtrl,
                  // Sur Flutter web desktop, `TextInputType.number` bloque
                  // la saisie clavier physique (issue Flutter #47788). On
                  // utilise `text` + formatter `digitsOnly` qui filtre quand
                  // même les caractères non numériques. Sur mobile, le pavé
                  // numérique reste accessible via le formatter.
                  keyboardType: TextInputType.text,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                  ],
                  autofocus: true,
                  onChanged: (_) => setState(() => _error = null),
                  style: const TextStyle(
                      fontSize: 13, color: Color(0xFF1A1D2E)),
                  decoration: InputDecoration(
                    hintText: '0',
                    prefixIcon: const Icon(Icons.inventory_2_outlined,
                        size: 15, color: Color(0xFFAAAAAA)),
                    filled: true,
                    fillColor: const Color(0xFFF9FAFB),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 11),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(
                            color: AppColors.divider)),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(
                            color: AppColors.primary, width: 1.5)),
                  ),
                ),
                if (d != null && d != 0) ...[
                  const SizedBox(height: 8),
                  Row(children: [
                    Icon(
                        d > 0
                            ? Icons.arrow_upward_rounded
                            : Icons.arrow_downward_rounded,
                        size: 13,
                        color: d > 0
                            ? AppColors.secondary
                            : AppColors.error),
                    const SizedBox(width: 4),
                    Text('${d > 0 ? '+' : ''}$d par rapport à l\'actuel',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: d > 0
                                ? AppColors.secondary
                                : AppColors.error)),
                  ]),
                ],
                const SizedBox(height: 12),
                const Row(children: [
                  Text('Raison',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: AppColors.textSecondary)),
                  SizedBox(width: 4),
                  Text('*',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: AppColors.error)),
                ]),
                const SizedBox(height: 4),
                TextField(
                  controller: _notesCtrl,
                  maxLines: 2,
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFF1A1D2E)),
                  decoration: InputDecoration(
                    hintText: 'Ex: correction après inventaire',
                    hintStyle: const TextStyle(
                        color: Color(0xFFBBBBBB), fontSize: 11),
                    filled: true,
                    fillColor: const Color(0xFFF9FAFB),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(
                            color: AppColors.divider)),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(
                            color: AppColors.primary, width: 1.5)),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!,
                      style: const TextStyle(
                          fontSize: 11, color: AppColors.error)),
                ],
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFFBEB),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFFFEF3C7)),
                  ),
                  child: Row(children: [
                    const Icon(Icons.info_outline_rounded,
                        size: 12, color: Color(0xFFB45309)),
                    const SizedBox(width: 6),
                    const Expanded(
                      child: Text(
                          'Cette correction sera enregistrée dans l\'historique du stock.',
                          style: TextStyle(
                              fontSize: 10, color: Color(0xFF92400E))),
                    ),
                  ]),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
            child: Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _submitting
                      ? null
                      : () => Navigator.of(context).pop(false),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 44),
                  ),
                  child: const Text('Annuler'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton(
                  onPressed: _submitting ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(0, 44),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  child: _submitting
                      ? const SizedBox(
                          width: 14, height: 14,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('Corriger'),
                ),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

/// Helper : ouvre le dialog en bottom sheet et renvoie `true` si l'ajustement
/// a été appliqué, `false` si annulé / valeur inchangée.
Future<bool> showAdjustStockSheet({
  required BuildContext context,
  required ProductVariant variant,
  required String shopId,
  required String productId,
}) async {
  final ok = await showFormSheet<bool>(
    context: context,
    builder: (_) => AdjustStockDialog(
      variant:   variant,
      shopId:    shopId,
      productId: productId,
    ),
  );
  return ok == true;
}
