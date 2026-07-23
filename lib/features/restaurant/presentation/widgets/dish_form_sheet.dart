import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/services/menu_modifier_service.dart';
import '../../../../core/services/pending_image_upload_service.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/utils/image_validation.dart';
import '../../../../features/inventaire/domain/entities/product.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_field.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../../../shared/widgets/product_image_card.dart';
import '../../domain/entities/menu_modifier.dart';

/// Ouvre la feuille de saisie d'un plat. Retourne `true` si un plat a été
/// créé ou modifié.
Future<bool?> showDishForm({
  required BuildContext context,
  required String shopId,
  Product? existing,
}) =>
    showAdaptiveFormSheet<bool>(
      context: context,
      builder: (_) => DishFormSheet(shopId: shopId, existing: existing),
    );

/// Saisie d'un plat — version courte du formulaire produit.
///
/// Cinq champs visibles (photo, nom, catégorie, prix, description), le reste
/// replié. Le formulaire produit complet reste réservé à l'e-commerce : SKU,
/// code-barres, fournisseur, frais de douane et emplacements de stock n'ont
/// pas de sens sur un plat cuisiné.
///
/// **Une variante implicite** est créée pour chaque plat. Elle n'apparaît
/// nulle part dans l'UI, mais elle est indispensable : le service d'upload
/// d'images écrit dans `variants[i].imageUrl` et abandonne si l'index est
/// hors bornes — un plat sans variante ne pourrait donc pas avoir de photo.
class DishFormSheet extends StatefulWidget {
  final String shopId;
  final Product? existing;

  const DishFormSheet({super.key, required this.shopId, this.existing});

  @override
  State<DishFormSheet> createState() => _DishFormSheetState();
}

class _DishFormSheetState extends State<DishFormSheet> {
  final _nameCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _costCtrl = TextEditingController();

  String? _category;
  Uint8List? _imageBytes;
  String? _existingImageUrl;

  /// Noms des groupes de modificateurs cochés pour ce plat.
  final Set<String> _groups = {};

  int _rating = 0;
  // Décoché par défaut, à l'inverse du défaut global : un plat est produit à
  // la commande. L'activer d'office ramènerait les stocks négatifs et le
  // bruit dans le journal que `track_stock` a précisément corrigés.
  bool _trackStock = false;
  bool _isActive = true;
  bool _advanced = false;

  bool _saving = false;
  String? _error;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final p = widget.existing;
    if (p != null) {
      _nameCtrl.text = p.name;
      _priceCtrl.text = p.priceSellPos == 0
          ? ''
          : p.priceSellPos.toStringAsFixed(0);
      _descCtrl.text = p.description ?? '';
      _costCtrl.text = p.priceBuy == 0 ? '' : p.priceBuy.toStringAsFixed(0);
      _category = p.categoryId;
      _existingImageUrl = p.mainImageUrl;
      _rating = p.rating;
      _trackStock = p.trackStock;
      _isActive = p.isActive;
      final pid = p.id;
      if (pid != null) {
        for (final m in MenuModifierService.forShop(widget.shopId)) {
          if (m.productId == pid) _groups.add(m.name);
        }
      }
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _priceCtrl.dispose();
    _descCtrl.dispose();
    _costCtrl.dispose();
    super.dispose();
  }

  List<String> get _categories =>
      LocalStorageService.getCategories(widget.shopId)..sort();

  /// Groupes de modificateurs proposables : ceux liés à un produit précis.
  /// Les groupes globaux (`productId == null`) s'appliquent déjà partout,
  /// les cocher n'aurait aucun effet.
  List<MenuModifier> get _linkableGroups {
    final byName = <String, MenuModifier>{};
    for (final m in MenuModifierService.forShop(widget.shopId)) {
      if (m.options.isEmpty) continue;
      if (m.productId == null) continue;
      byName.putIfAbsent(m.name, () => m);
    }
    return byName.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  Future<void> _pickImage() async {
    final xFile = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (xFile == null || !mounted) return;
    final result = await validateAndReadImage(xFile, context);
    if (!mounted || !result.isValid) return;
    setState(() => _imageBytes = result.bytes);
  }

  Future<void> _addCategory() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nouvelle catégorie'),
        content: AppField(
          controller: ctrl,
          hint: 'Entrées, Plats, Boissons…',
          autofocus: true,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Annuler')),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
              child: const Text('Ajouter')),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || name.isEmpty || !mounted) return;
    await AppDatabase.saveCategory(widget.shopId, name);
    if (mounted) setState(() => _category = name);
  }

  Future<void> _submit() async {
    final name = _nameCtrl.text.trim();
    final price = double.tryParse(_priceCtrl.text.trim().replaceAll(',', '.'));

    if (name.isEmpty) {
      setState(() => _error = 'Donnez un nom au plat.');
      return;
    }
    if (_category == null || _category!.isEmpty) {
      setState(() => _error = 'Choisissez une catégorie.');
      return;
    }
    if (price == null || price <= 0) {
      setState(() => _error = 'Indiquez un prix valide.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      final ts = DateTime.now().millisecondsSinceEpoch;
      final existing = widget.existing;
      final productId = existing?.id ?? 'prod_$ts';
      final cost = double.tryParse(
              _costCtrl.text.trim().replaceAll(',', '.')) ??
          0;

      // Variante implicite : conserve celle du plat en édition (elle porte
      // l'URL d'image déjà uploadée), sinon on en crée une.
      final baseVariant = (existing != null && existing.variants.isNotEmpty)
          ? existing.variants.first
          : ProductVariant(id: 'var_$ts', name: name);

      final variant = baseVariant.copyWith(
        name: name,
        priceBuy: cost,
        priceSellPos: price,
        priceSellWeb: price,
      );

      final product = Product(
        id: productId,
        storeId: widget.shopId,
        name: name,
        categoryId: _category,
        description: _descCtrl.text.trim().isEmpty
            ? null
            : _descCtrl.text.trim(),
        priceBuy: cost,
        // Un seul prix : la distinction comptoir / web est une notion
        // e-commerce, sans objet sur une carte de restaurant.
        priceSellPos: price,
        priceSellWeb: price,
        isActive: _isActive,
        isVisibleWeb: _isActive,
        trackStock: _trackStock,
        rating: _rating,
        imageUrl: existing?.imageUrl,
        variants: [variant],
        createdAt: existing?.createdAt ?? DateTime.now(),
      );

      await AppDatabase.saveProduct(product, skipValidation: true);

      if (_imageBytes != null) {
        await PendingImageUploadService.enqueue(
          shopId: widget.shopId,
          productId: productId,
          variantIdx: 0,
          bytes: _imageBytes!,
          name: 'shops/${widget.shopId}/products/${ts}_0',
          // Les bytes sortent de `validateAndReadImage` déjà ré-encodés en
          // PNG : annoncer un autre type ferait enregistrer du PNG sous une
          // extension mensongère.
          mimeType: 'image/png',
          isPrimary: true,
        );
        unawaited(PendingImageUploadService.flush());
      }

      await _syncModifierLinks(productId);

      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.toString();
        });
      }
    }
  }

  /// Aligne les liaisons de modificateurs sur les cases cochées : crée les
  /// manquantes, supprime celles qu'on vient de décocher.
  Future<void> _syncModifierLinks(String productId) async {
    final all = MenuModifierService.forShop(widget.shopId);
    final linked = {
      for (final m in all)
        if (m.productId == productId) m.name: m,
    };

    for (final name in _groups) {
      if (linked.containsKey(name)) continue;
      final source = all.firstWhere((m) => m.name == name,
          orElse: () => all.first);
      await MenuModifierService.addGroup(
        shopId: widget.shopId,
        name: name,
        options: source.options,
        productIds: [productId],
      );
    }
    for (final entry in linked.entries) {
      if (_groups.contains(entry.key)) continue;
      await MenuModifierService.delete(entry.value.id, widget.shopId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem = theme.semantic;
    final cs = theme.colorScheme;
    final groups = _linkableGroups;

    return AdaptiveFormFrame(
      title: _isEdit ? 'Modifier le plat' : 'Nouveau plat',
      icon: Icons.restaurant_rounded,
      iconColor: AppColors.primary,
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Photo ────────────────────────────────────────────────
            Center(
              child: InkWell(
                onTap: _pickImage,
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  width: 190,
                  height: 132,
                  decoration: BoxDecoration(
                    color: sem.trackMuted,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: sem.borderSubtle),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: _imageBytes != null
                      ? Image.memory(_imageBytes!, fit: BoxFit.cover)
                      : (_existingImageUrl != null
                          ? ProductImageCard(
                              imageUrl: _existingImageUrl,
                              fillParent: true,
                              borderRadius: BorderRadius.zero,
                            )
                          : Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.photo_camera_outlined,
                                    size: 26,
                                    color: cs.onSurface
                                        .withValues(alpha: 0.45)),
                                const SizedBox(height: 6),
                                Text('Ajouter une photo',
                                    style: AppTextStyles.caption),
                              ],
                            )),
                ),
              ),
            ),
            const SizedBox(height: 18),

            // ── Nom ──────────────────────────────────────────────────
            const AppFieldLabel('Nom du plat', required: true),
            const SizedBox(height: 8),
            AppField(
              controller: _nameCtrl,
              hint: 'Poulet DG',
              autofocus: !_isEdit,
              prefixIcon: Icons.restaurant_rounded,
            ),
            const SizedBox(height: 16),

            // ── Catégorie ────────────────────────────────────────────
            const AppFieldLabel('Catégorie', required: true),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in _categories)
                  _Chip(
                    label: c,
                    selected: _category == c,
                    onTap: () => setState(() => _category = c),
                  ),
                _Chip(
                  label: '+ Nouvelle',
                  selected: false,
                  onTap: _addCategory,
                ),
              ],
            ),
            const SizedBox(height: 16),

            // ── Prix ─────────────────────────────────────────────────
            const AppFieldLabel('Prix', required: true),
            const SizedBox(height: 8),
            AppField(
              controller: _priceCtrl,
              hint: '3500',
              numbersOnly: true,
              keyboardType: TextInputType.number,
              prefixIcon: Icons.payments_outlined,
              suffixIcon: Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Text(CurrencyFormatter.currentSymbol,
                    style: AppTextStyles.bodySmSecondary),
              ),
            ),
            const SizedBox(height: 16),

            // ── Description ──────────────────────────────────────────
            const AppFieldLabel('Description'),
            const SizedBox(height: 8),
            AppField(
              controller: _descCtrl,
              hint: 'Poulet, plantain, légumes sautés…',
              maxLines: 2,
            ),

            // ── Options ──────────────────────────────────────────────
            if (groups.isNotEmpty) ...[
              const SizedBox(height: 16),
              const AppFieldLabel('Options proposées'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final g in groups)
                    _Chip(
                      label: g.name,
                      selected: _groups.contains(g.name),
                      onTap: () => setState(() {
                        if (!_groups.remove(g.name)) _groups.add(g.name);
                      }),
                    ),
                ],
              ),
            ],

            // ── Réglages avancés ─────────────────────────────────────
            const SizedBox(height: 8),
            InkWell(
              onTap: () => setState(() => _advanced = !_advanced),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  children: [
                    Icon(
                        _advanced
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        size: 20,
                        color: cs.onSurface),
                    const SizedBox(width: 6),
                    Text('Plus de réglages',
                        style: AppTextStyles.bodySmBold
                            .copyWith(color: cs.onSurface)),
                  ],
                ),
              ),
            ),
            if (_advanced) ...[
              const AppFieldLabel('Coût matière'),
              const SizedBox(height: 8),
              AppField(
                controller: _costCtrl,
                hint: '0',
                numbersOnly: true,
                keyboardType: TextInputType.number,
                prefixIcon: Icons.savings_outlined,
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  const Expanded(child: AppFieldLabel('Note')),
                  for (var i = 1; i <= 5; i++)
                    InkWell(
                      // Re-tap sur l'étoile active remet la note à zéro.
                      onTap: () => setState(
                          () => _rating = _rating == i ? 0 : i),
                      child: Icon(
                        i <= _rating
                            ? Icons.star_rounded
                            : Icons.star_border_rounded,
                        size: 24,
                        color: i <= _rating
                            ? sem.warning
                            : cs.onSurface.withValues(alpha: 0.3),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              _Toggle(
                label: 'Suivi du stock',
                hint: 'À activer pour les boissons en bouteille, '
                    'pas pour un plat cuisiné',
                value: _trackStock,
                onChanged: (v) => setState(() => _trackStock = v),
              ),
              _Toggle(
                label: 'Disponible à la vente',
                hint: 'Décochez pour retirer temporairement de la carte',
                value: _isActive,
                onChanged: (v) => setState(() => _isActive = v),
              ),
            ],

            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!,
                  style:
                      AppTextStyles.caption.copyWith(color: sem.danger)),
            ],
            const SizedBox(height: 20),
            AppPrimaryButton(
              label: _isEdit ? 'Enregistrer' : 'Créer le plat',
              icon: Icons.check_rounded,
              fullWidth: true,
              isLoading: _saving,
              onTap: _submit,
            ),
          ],
        ),
      ),
    );
  }
}

/// Puce de sélection (catégorie ou groupe d'options).
class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem = theme.semantic;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primary.withValues(alpha: 0.12)
              : sem.trackMuted,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? AppColors.primary : sem.borderSubtle,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Text(
          label,
          style: AppTextStyles.bodySm.copyWith(
            color: selected
                ? AppColors.primary
                : theme.colorScheme.onSurface,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

/// Interrupteur avec libellé et explication.
class _Toggle extends StatelessWidget {
  final String label;
  final String hint;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _Toggle({
    required this.label,
    required this.hint,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: AppTextStyles.bodySmBold
                        .copyWith(color: cs.onSurface)),
                Text(hint, style: AppTextStyles.micro),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}
