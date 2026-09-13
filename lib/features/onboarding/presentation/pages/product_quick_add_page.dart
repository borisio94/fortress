import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/services/pending_image_upload_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/utils/image_validation.dart';
import '../../../../shared/widgets/app_field.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/form_sheet.dart';
import '../../../inventaire/domain/entities/product.dart';
import '../../../inventaire/presentation/bloc/inventaire_bloc.dart';
import '../../../inventaire/presentation/bloc/inventaire_event.dart';
import '../../../inventaire/presentation/pages/product_form_page.dart'
    show ProductFormExtra;

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
  final _buyCtrl   = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _stockCtrl = TextEditingController(text: '0');

  /// Photo choisie, déjà validée et ré-encodée en PNG. Envoyée après la
  /// création, par la file d'attente — comme dans la fiche complète.
  Uint8List? _imageBytes;

  bool _submitting = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _buyCtrl.dispose();
    _priceCtrl.dispose();
    _stockCtrl.dispose();
    super.dispose();
  }

  double get _buy  => double.tryParse(_buyCtrl.text.replaceAll(',', '.')) ?? 0;
  double get _sell => double.tryParse(_priceCtrl.text.replaceAll(',', '.')) ?? 0;

  bool get _isValid {
    final name  = _nameCtrl.text.trim();
    final price = double.tryParse(_priceCtrl.text.replaceAll(',', '.'));
    final stock = int.tryParse(_stockCtrl.text);
    return name.length >= 2
        && price != null && price >= 0
        && stock != null && stock >= 0;
  }

  /// Demande la source de la photo. Sur le web de bureau, « Prendre une
  /// photo » retombe d'elle-même sur le sélecteur de fichiers.
  Future<ImageSource?> _askImageSource() => showFormSheet<ImageSource>(
    context: context,
    builder: (dc) => SafeArea(
      top: false,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const FormSheetHeader(
            title: 'Ajouter une photo', icon: Icons.add_a_photo_outlined),
        ListTile(
          leading: Icon(Icons.photo_camera_outlined,
              size: 20, color: AppColors.primary),
          title: const Text('Prendre une photo'),
          onTap: () => Navigator.of(dc).pop(ImageSource.camera),
        ),
        ListTile(
          leading: Icon(Icons.photo_library_outlined,
              size: 20, color: AppColors.primary),
          title: const Text('Choisir dans la galerie'),
          onTap: () => Navigator.of(dc).pop(ImageSource.gallery),
        ),
        const SizedBox(height: 8),
      ]),
    ),
  );

  Future<void> _pickImage() async {
    final source = await _askImageSource();
    if (source == null || !mounted) return;
    XFile? xFile;
    try {
      xFile = await ImagePicker().pickImage(source: source);
    } catch (_) {
      // ÉCRAN NOIR SUR WEB. La caméra y dépend du navigateur et d'une
      // permission qui peut être refusée sans un mot : `image_picker` lève
      // alors au lieu de rendre la main, et l'utilisateur restait devant un
      // écran noir. On le dit, et on bascule sur le sélecteur de fichiers,
      // qui fonctionne partout.
      if (!kIsWeb || source != ImageSource.camera) rethrow;
      if (!mounted) return;
      AppSnack.info(context, 'Sélectionnez une photo depuis votre galerie');
      xFile = await ImagePicker().pickImage(source: ImageSource.gallery);
    }
    if (xFile == null || !mounted) return;
    // Même validation que la fiche complète : refus sous 800×800,
    // 1600 px max, ré-encodage PNG sans perte.
    final result = await validateAndReadImage(xFile, context);
    if (!mounted || !result.isValid) return;
    setState(() => _imageBytes = result.bytes);
  }

  /// Bascule vers la fiche complète EN CONSERVANT la saisie.
  ///
  /// Le bouton renvoyait jusqu'ici vers `/inventaire` : tout ce qui venait
  /// d'être tapé était perdu, et l'utilisateur devait recommencer. On
  /// construit ici un produit NON PERSISTÉ (`id: null` — rien n'est écrit) et
  /// on le passe en `extra`. `ProductFormPage` le traite comme n'importe quel
  /// pré-remplissage : ses champs se garnissent, et comme ce produit n'a
  /// aucune variante, la fiche en fabrique une de base qui reprend prix
  /// d'achat, prix de vente et stock.
  void _openFullForm() {
    final draft = Product(
      storeId:      widget.shopId,
      name:         _nameCtrl.text.trim(),
      priceBuy:     _buy,
      priceSellPos: _sell,
      stockQty:     int.tryParse(_stockCtrl.text) ?? 0,
      createdAt:    DateTime.now(),
    );
    context.go('/shop/${widget.shopId}/inventaire/product',
        extra: ProductFormExtra(
            product: draft, isQuickAddContinuation: true));
  }

  Future<void> _submit() async {
    if (!_isValid || _submitting) return;
    setState(() => _submitting = true);
    final now = DateTime.now();
    final id  = 'prod_${now.microsecondsSinceEpoch}';
    final qty = int.tryParse(_stockCtrl.text) ?? 0;
    // Produit construit ICI plutôt que via `AddProductParams.toProduct` :
    // il lui faut une variante de base explicite, sinon la photo n'a rien
    // à quoi se rattacher (la file d'upload abandonne toute entrée dont
    // l'index de variante dépasse la liste).
    final product = Product(
      id:           id,
      storeId:      widget.shopId,
      name:         _nameCtrl.text.trim(),
      priceBuy:     _buy,
      priceSellPos: _sell,
      stockQty:     qty,
      isVisibleWeb: true,
      createdAt:    now,
      variants: [
        ProductVariant(
          id:             'var_${now.microsecondsSinceEpoch}_0',
          name:           'Base',
          priceBuy:       _buy,
          priceSellPos:   _sell,
          stockAvailable: qty,
          stockPhysical:  qty,
          isMain:         true,
        ),
      ],
    );
    try {
      await AppDatabase.saveProduct(product);
      if (_imageBytes != null) {
        await PendingImageUploadService.enqueue(
          shopId:     widget.shopId,
          productId:  id,
          variantIdx: 0,
          bytes:      _imageBytes!,
          name:       'shops/${widget.shopId}/products/'
                      '${now.microsecondsSinceEpoch}_0',
        );
        unawaited(PendingImageUploadService.flush());
      }
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
            onPressed: _openFullForm,
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
                      'En quelques champs, votre produit est prêt à vendre. '
                      'Variantes, TVA et fournisseur restent disponibles '
                      'dans la fiche complète.',
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
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: _LabeledField(
                  label: 'Prix d\'achat',
                  child: AppField(
                    controller: _buyCtrl,
                    hint:  'Ex. 350',
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    onChanged: (_) => setState(() {}),
                  ),
                )),
                const SizedBox(width: 12),
                Expanded(child: _LabeledField(
                  label: 'Prix de vente',
                  child: AppField(
                    controller: _priceCtrl,
                    hint:  'Ex. 500',
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    onChanged: (_) => setState(() {}),
                  ),
                )),
              ]),
              // Bandeau bénéfice/marge — n'apparaît qu'une fois les deux
              // prix saisis, comme dans la fiche complète.
              if (_buy > 0 && _sell > 0) ...[
                const SizedBox(height: 12),
                _MarginBanner(buy: _buy, sell: _sell),
              ],
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
              const SizedBox(height: 18),
              _PhotoPicker(
                bytes: _imageBytes,
                onPick: _pickImage,
                onClear: () => setState(() => _imageBytes = null),
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

/// Bénéfice et marge en direct. `_BenefitBanner` de la fiche complète est
/// privé à son fichier : on refait le même calcul, sans les dépenses de lot
/// qui n'existent pas dans la saisie rapide.
class _MarginBanner extends StatelessWidget {
  final double buy, sell;
  const _MarginBanner({required this.buy, required this.sell});

  @override
  Widget build(BuildContext context) {
    final benefit = sell - buy;
    final margin  = sell > 0 ? benefit / sell * 100 : 0.0;
    final positive = benefit > 0;
    final color = positive ? AppColors.secondary : AppColors.error;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(children: [
        Expanded(child: _cell('Prix de revient', buy.toStringAsFixed(0),
            AppColors.textSecondary)),
        Expanded(child: _cell('Bénéfice',
            benefit.toStringAsFixed(0), color)),
        Expanded(child: _cell('Marge',
            '${margin.toStringAsFixed(0)} %', color)),
      ]),
    );
  }

  Widget _cell(String label, String value, Color color) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: AppTextStyles.micro),
      const SizedBox(height: 2),
      Text(value, style: AppTextStyles.bodyBold.copyWith(color: color)),
    ],
  );
}

/// Zone photo : vignette si une image est choisie, cadre d'appel sinon.
class _PhotoPicker extends StatelessWidget {
  final Uint8List? bytes;
  final VoidCallback onPick;
  final VoidCallback onClear;
  const _PhotoPicker({
    required this.bytes, required this.onPick, required this.onClear});

  @override
  Widget build(BuildContext context) {
    if (bytes == null) {
      return OutlinedButton.icon(
        onPressed: onPick,
        icon: const Icon(Icons.add_a_photo_outlined, size: 18),
        label: const Text('Ajouter une photo (facultatif)'),
        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 46)),
      );
    }
    return Row(children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(bytes!, width: 64, height: 64, fit: BoxFit.cover),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Text('Photo prête — elle partira après l\'enregistrement.',
            style: AppTextStyles.micro.copyWith(
                color: AppColors.textSecondary)),
      ),
      IconButton(
        onPressed: onClear,
        icon: const Icon(Icons.close_rounded, size: 18),
        color: AppColors.error,
        tooltip: 'Retirer la photo',
      ),
    ]);
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
