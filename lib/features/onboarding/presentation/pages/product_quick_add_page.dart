import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../shared/widgets/app_field.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../inventaire/domain/entities/product.dart';
import '../../../inventaire/domain/usecases/add_product_usecase.dart';
import '../../../inventaire/presentation/bloc/inventaire_bloc.dart';
import '../../../inventaire/presentation/bloc/inventaire_event.dart';

/// Ajout produit éclair (point 7 de l'onboarding spec).
///
/// 3 champs visibles : nom · prix de vente · stock initial.
/// Tous les autres aspects (variantes, catégorie, prix d'achat, TVA,
/// photos…) restent disponibles via `ProductFormPage` (« Options
/// avancées ») — non répliqués ici pour ne pas confondre l'utilisateur
/// au premier ajout.
///
/// La page crée un produit sans variantes (variante de base auto-générée
/// par `LocalStorageService._productFromMap` à la 1ʳᵉ lecture si absent).
/// Utilisable depuis la checklist d'activation du dashboard.
class ProductQuickAddPage extends StatefulWidget {
  final String shopId;
  const ProductQuickAddPage({super.key, required this.shopId});

  @override
  State<ProductQuickAddPage> createState() => _ProductQuickAddPageState();
}

class _ProductQuickAddPageState extends State<ProductQuickAddPage> {
  final _nameCtrl  = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _stockCtrl = TextEditingController(text: '0');

  bool _submitting = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _priceCtrl.dispose();
    _stockCtrl.dispose();
    super.dispose();
  }

  bool get _isValid {
    final name  = _nameCtrl.text.trim();
    final price = double.tryParse(_priceCtrl.text.replaceAll(',', '.'));
    final stock = int.tryParse(_stockCtrl.text);
    return name.length >= 2
        && price != null && price >= 0
        && stock != null && stock >= 0;
  }

  Future<void> _submit() async {
    if (!_isValid || _submitting) return;
    setState(() => _submitting = true);
    final params = AddProductParams(
      shopId:       widget.shopId,
      name:         _nameCtrl.text.trim(),
      priceSellPos: double.tryParse(
              _priceCtrl.text.replaceAll(',', '.')) ?? 0,
      stockQty:     int.tryParse(_stockCtrl.text) ?? 0,
    );
    // On passe par le bloc Inventaire pour garder le pattern existant
    // (rafraîchissement liste + activity_log). En cas de bloc indispo,
    // fallback direct AppDatabase.saveProduct.
    try {
      final product = params.toProduct(widget.shopId);
      await AppDatabase.saveProduct(product);
      // Trigger inventaire reload si bloc présent.
      try {
        // ignore: use_build_context_synchronously
        context.read<InventaireBloc>().add(LoadProducts(widget.shopId));
      } catch (_) {/* bloc pas monté à cette route, OK */}
      if (!mounted) return;
      AppSnack.success(context, 'Produit ajouté à votre catalogue');
      context.pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      AppSnack.error(context, 'Erreur : ${e.toString()}');
    }
    // Fallback noop pour éviter warning unused.
    if (!mounted) return;
    if (_submitting) setState(() => _submitting = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Ajout rapide'),
        actions: [
          TextButton.icon(
            onPressed: () => context.go(
                '/shop/${widget.shopId}/inventaire'),
            icon:  const Icon(Icons.tune_rounded, size: 16),
            label: const Text('Options avancées'),
            style: TextButton.styleFrom(
                foregroundColor: AppColors.textSecondary),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Header didactique ───────────────────────────────────
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(children: [
                  Icon(Icons.bolt_rounded,
                      color: AppColors.primary, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'En 3 champs, votre 1ᵉʳ produit est prêt à vendre. '
                      'Vous pourrez ajouter variantes et photos plus tard.',
                      style: AppTextStyles.bodySm.copyWith(
                          color: AppColors.textPrimary),
                    ),
                  ),
                ]),
              ),
              const SizedBox(height: 24),

              _LabeledField(
                label: 'Nom du produit',
                child: AppField(
                  controller: _nameCtrl,
                  hint:  'Ex. Eau minérale 50cl',
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(height: 14),
              _LabeledField(
                label: 'Prix de vente (FCFA)',
                child: AppField(
                  controller: _priceCtrl,
                  hint:  'Ex. 500',
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(height: 14),
              _LabeledField(
                label: 'Stock initial',
                child: AppField(
                  controller: _stockCtrl,
                  hint:  'Ex. 24',
                  keyboardType: TextInputType.number,
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(height: 28),

              AppPrimaryButton(
                label:     'Ajouter au catalogue',
                icon:      Icons.add_rounded,
                enabled:   _isValid,
                isLoading: _submitting,
                onTap:     _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Helper local : label `AppTextStyles.label` au-dessus du field.
/// `AppField` n'a pas de paramètre `label` natif (cf. AppFieldLabel
/// pour le composant dédié, mais on garde simple ici).
class _LabeledField extends StatelessWidget {
  final String label;
  final Widget child;
  const _LabeledField({required this.label, required this.child});
  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 6),
            child: Text(label, style: AppTextStyles.label),
          ),
          child,
        ],
      );
}
