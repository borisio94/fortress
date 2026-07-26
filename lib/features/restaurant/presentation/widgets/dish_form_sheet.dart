import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:image_picker/image_picker.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/services/activity_service.dart';
import '../../../../core/services/menu_modifier_service.dart';
import '../../../../core/services/ingredient_service.dart';
import '../../../../core/services/recipe_service.dart';
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
import '../../../../shared/widgets/app_confirm_dialog.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/product_image_card.dart';
import '../../domain/entities/menu_modifier.dart';
import '../../domain/entities/ingredient.dart';
import '../../domain/entities/restaurant_activity.dart';

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

  /// Activités connexes de la boutique — le « secteur » du plat (hotfix_141).
  /// Liste vide (aucune activité créée) → la section n'apparaît pas.
  late final List<RestaurantActivity> _activities =
      ActivityService.forShop(widget.shopId);

  /// Secteur sélectionné (`restaurant_activities.id`), null = aucun.
  String? _activityId;

  /// Noms des groupes de modificateurs cochés pour ce plat.
  final Set<String> _groups = {};

  /// Brouillon de fiche recette (persisté en base seulement au save, avec le
  /// productId — définitif après la création du plat).
  final List<_RecipeDraft> _recipe = [];

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
      // Secteur : ignoré si l'activité a été supprimée entre-temps — sans ce
      // filtre, le formulaire réenregistrerait en silence un id orphelin.
      _activityId = _activities.any((a) => a.id == p.activityId)
          ? p.activityId
          : null;
      _existingImageUrl = p.mainImageUrl;
      _rating = p.rating;
      _trackStock = p.trackStock;
      _isActive = p.isActive;
      final pid = p.id;
      if (pid != null) {
        for (final m in MenuModifierService.forShop(widget.shopId)) {
          if (m.productId == pid) _groups.add(m.name);
        }
        // Charge la fiche recette existante (lignes + infos ingrédient).
        for (final line in RecipeService.forProduct(widget.shopId, pid)) {
          final ing = IngredientService.byId(widget.shopId, line.ingredientId);
          _recipe.add(_RecipeDraft(
            ingredientId: line.ingredientId,
            name: ing?.name ?? '(ingrédient supprimé)',
            unit: line.unit,
            quantity: line.quantity,
            costPerUnit: ing?.costPerUnit ?? 0,
            isShared: ing?.isShared ?? false,
          ));
        }
      }
    }
    _priceCtrl.addListener(_onMarginInputsChanged);
  }

  @override
  void dispose() {
    _priceCtrl.removeListener(_onMarginInputsChanged);
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
        activityId: _activityId,
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
      await _syncRecipeLines(productId);

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

  // ── Fiche recette ──────────────────────────────────────────────────────

  /// Aligne les lignes de recette persistées sur le brouillon `_recipe` :
  /// (ré)ajoute les présentes (upsert par couple plat/ingrédient), supprime
  /// celles retirées de la liste.
  Future<void> _syncRecipeLines(String productId) async {
    final currentIds = _recipe.map((d) => d.ingredientId).toSet();
    for (final line in RecipeService.forProduct(widget.shopId, productId)) {
      if (!currentIds.contains(line.ingredientId)) {
        await RecipeService.removeLine(line);
      }
    }
    for (final d in _recipe) {
      await RecipeService.addLine(
        shopId: widget.shopId,
        productId: productId,
        ingredientId: d.ingredientId,
        quantity: d.quantity,
        unit: d.unit,
      );
    }
  }

  /// Coût matières d'une ligne (prorata partagé compris) — estimation live.
  double _draftCost(_RecipeDraft d) {
    final full = d.quantity * d.costPerUnit;
    if (!d.isShared) return full;
    final n =
        RecipeService.dishCountForIngredient(widget.shopId, d.ingredientId);
    return n <= 1 ? full : full / n;
  }

  double get _recipeCost => _recipe.fold(0.0, (s, d) => s + _draftCost(d));

  /// Feuille d'ajout : choisir un ingrédient existant OU en créer un inline,
  /// + la quantité utilisée par plat.
  Future<void> _addRecipeIngredient() async {
    final result = await showAdaptiveFormSheet<_RecipeLineResult>(
      context: context,
      builder: (_) => _AddRecipeIngredientSheet(shopId: widget.shopId),
    );
    if (result == null || !mounted) return;
    setState(() {
      final ing = result.ingredient;
      _recipe.removeWhere((d) => d.ingredientId == ing.id);
      _recipe.add(_RecipeDraft(
        ingredientId: ing.id,
        name: ing.name,
        unit: result.unit,
        quantity: result.quantity,
        costPerUnit: ing.costPerUnit,
        isShared: ing.isShared,
      ));
    });
  }

  /// Le champ prix pilote la marge affichée → rebuild live quand il change.
  void _onMarginInputsChanged() {
    if (mounted && _recipe.isNotEmpty) setState(() {});
  }

  /// Supprime le plat (édition uniquement). Soft-delete réversible depuis
  /// l'historique. Un motif par défaut satisfait le garde-fou serveur
  /// (raison ≥ 10 caractères) sans imposer de saisie à l'opérateur.
  Future<void> _deleteDish() async {
    final existing = widget.existing;
    final pid = existing?.id;
    if (pid == null || pid.isEmpty) return;
    final confirmed = await AppConfirmDialog.show(
      context: context,
      icon: Icons.delete_outline_rounded,
      iconColor: Theme.of(context).semantic.danger,
      title: 'Supprimer ce plat ?',
      body: Text('« ${existing!.name} » sera retiré de la carte. '
          'Action réversible depuis l\'historique.'),
      cancelLabel: 'Annuler',
      confirmLabel: 'Supprimer',
      onConfirm: () {},
    );
    if (confirmed != true || !mounted) return;
    try {
      await AppDatabase.deleteProduct(
        pid,
        reason: 'Plat retiré de la carte',
        userId: LocalStorageService.getCurrentUser()?.id ?? '',
      );
      // Ferme le formulaire en signalant un changement → la carte se rafraîchit
      // et le plat (soft-deleted) disparaît (getProductsForShop filtre isDeleted).
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) AppSnack.error(context, 'Suppression impossible : $e');
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

            // ── Secteur (activité connexe) ───────────────────────────
            // Masqué tant qu'aucune activité n'existe : une carte simple
            // n'a pas à porter une notion de secteur inutilisée. Se crée
            // depuis Finances › Activités.
            if (_activities.isNotEmpty) ...[
              const AppFieldLabel('Secteur'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _Chip(
                    label: 'Aucun',
                    selected: _activityId == null,
                    onTap: () => setState(() => _activityId = null),
                  ),
                  for (final a in _activities)
                    _Chip(
                      label: a.name,
                      selected: _activityId == a.id,
                      onTap: () => setState(() => _activityId = a.id),
                    ),
                ],
              ),
              const SizedBox(height: 16),
            ],

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

            // ── Fiche recette ────────────────────────────────────────────
            const SizedBox(height: 20),
            Row(children: [
              Icon(Icons.receipt_long_outlined,
                  size: 18, color: AppColors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Fiche recette',
                    style: AppTextStyles.subtitle
                        .copyWith(color: cs.onSurface)),
              ),
              TextButton.icon(
                onPressed: _addRecipeIngredient,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('Ingrédient'),
              ),
            ]),
            if (_recipe.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                    'Ajoutez les ingrédients pour calculer le coût '
                    'matières et la marge.',
                    style: AppTextStyles.caption),
              )
            else ...[
              for (final d in _recipe)
                _RecipeRow(
                  draft: d,
                  cost: _draftCost(d),
                  onRemove: () => setState(() => _recipe.remove(d)),
                ),
              const SizedBox(height: 10),
              _RecipeSummary(
                cost: _recipeCost,
                price: double.tryParse(
                        _priceCtrl.text.trim().replaceAll(',', '.')) ??
                    0,
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
            // Suppression — édition uniquement. Discret, sous le bouton
            // principal, en rouge pour signaler l'action destructive.
            if (_isEdit) ...[
              const SizedBox(height: 6),
              Center(
                child: TextButton.icon(
                  onPressed: _saving ? null : _deleteDish,
                  icon: Icon(Icons.delete_outline_rounded,
                      size: 18, color: sem.danger),
                  label: Text('Supprimer le plat',
                      style: AppTextStyles.label.copyWith(color: sem.danger)),
                ),
              ),
            ],
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

// ═══════════════════════════════════════════════════════════════════════
//  FICHE RECETTE (module finances — PR-A)
// ═══════════════════════════════════════════════════════════════════════

/// Ligne de recette en cours d'édition (non encore persistée).
class _RecipeDraft {
  final String ingredientId;
  final String name;
  final String unit;
  final double quantity;
  final int costPerUnit;
  final bool isShared;
  const _RecipeDraft({
    required this.ingredientId,
    required this.name,
    required this.unit,
    required this.quantity,
    required this.costPerUnit,
    required this.isShared,
  });
}

/// Résultat de la feuille d'ajout d'ingrédient à la recette.
class _RecipeLineResult {
  final Ingredient ingredient;
  final double quantity;
  final String unit;
  const _RecipeLineResult(this.ingredient, this.quantity, this.unit);
}

/// Une ligne de la fiche recette : nom · quantité · coût · retrait.
class _RecipeRow extends StatelessWidget {
  final _RecipeDraft draft;
  final double cost;
  final VoidCallback onRemove;
  const _RecipeRow(
      {required this.draft, required this.cost, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    final q = draft.quantity == draft.quantity.truncateToDouble()
        ? draft.quantity.toInt().toString()
        : draft.quantity.toStringAsFixed(1);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(draft.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.bodyBold.copyWith(color: cs.onSurface)),
              Text('$q ${draft.unit}${draft.isShared ? ' · partagé' : ''}',
                  style: AppTextStyles.caption),
            ],
          ),
        ),
        Text(CurrencyFormatter.format(cost),
            style: AppTextStyles.bodyBold.copyWith(color: cs.onSurface)),
        IconButton(
          onPressed: onRemove,
          visualDensity: VisualDensity.compact,
          icon: Icon(Icons.close_rounded, size: 18, color: sem.danger),
        ),
      ]),
    );
  }
}

/// Bloc récapitulatif : coût matières · prix de vente · marge (FCFA + %).
class _RecipeSummary extends StatelessWidget {
  final double cost;
  final double price;
  const _RecipeSummary({required this.cost, required this.price});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    final margin = price - cost;
    final pct = price <= 0 ? 0.0 : (margin / price) * 100;
    final good = margin >= 0;
    final accent = good ? sem.success : sem.danger;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: sem.borderSubtle),
      ),
      child: Column(children: [
        _line(context, 'Coût matières', CurrencyFormatter.format(cost)),
        _line(context, 'Prix de vente', CurrencyFormatter.format(price)),
        Divider(height: 16, color: sem.borderSubtle),
        _line(context, 'Marge', CurrencyFormatter.format(margin),
            color: accent, bold: true),
        _line(context, 'Marge %', '${pct.toStringAsFixed(0)} %', color: accent),
      ]),
    );
  }

  Widget _line(BuildContext c, String label, String value,
      {Color? color, bool bold = false}) {
    final cs = Theme.of(c).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Expanded(
          child: Text(label,
              style: AppTextStyles.bodySm
                  .copyWith(color: cs.onSurface.withValues(alpha: 0.7))),
        ),
        Text(value,
            style: (bold ? AppTextStyles.bodyBold : AppTextStyles.bodySm)
                .copyWith(color: color ?? cs.onSurface)),
      ]),
    );
  }
}

/// Feuille : choisir un ingrédient existant OU en créer un inline, + quantité.
class _AddRecipeIngredientSheet extends StatefulWidget {
  final String shopId;
  const _AddRecipeIngredientSheet({required this.shopId});
  @override
  State<_AddRecipeIngredientSheet> createState() =>
      _AddRecipeIngredientSheetState();
}

class _AddRecipeIngredientSheetState
    extends State<_AddRecipeIngredientSheet> {
  late final List<Ingredient> _existing =
      IngredientService.forShop(widget.shopId);
  Ingredient? _selected;
  bool _new = false;
  final _nameCtrl = TextEditingController();
  final _unitCtrl = TextEditingController(text: 'g');
  final _costCtrl = TextEditingController();
  final _qtyCtrl = TextEditingController();
  String? _err;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _unitCtrl.dispose();
    _costCtrl.dispose();
    _qtyCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final qty = double.tryParse(_qtyCtrl.text.trim().replaceAll(',', '.'));
    if (qty == null || qty <= 0) {
      setState(() => _err = 'Quantité invalide');
      return;
    }
    Ingredient ing;
    String unit;
    if (_new || _existing.isEmpty) {
      final name = _nameCtrl.text.trim();
      if (name.isEmpty) {
        setState(() => _err = 'Nom de l\'ingrédient requis');
        return;
      }
      unit = _unitCtrl.text.trim().isEmpty ? 'pièce' : _unitCtrl.text.trim();
      ing = await IngredientService.create(
        shopId: widget.shopId,
        name: name,
        unit: unit,
        costPerUnit: int.tryParse(_costCtrl.text.trim()) ?? 0,
      );
    } else {
      if (_selected == null) {
        setState(() => _err = 'Choisissez un ingrédient');
        return;
      }
      ing = _selected!;
      unit = ing.unit;
    }
    if (mounted) {
      Navigator.of(context).pop(_RecipeLineResult(ing, qty, unit));
    }
  }

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    final creating = _new || _existing.isEmpty;
    final suffix = creating
        ? (_unitCtrl.text.trim().isEmpty ? null : _unitCtrl.text.trim())
        : _selected?.unit;
    return AdaptiveFormFrame(
      title: 'Ajouter un ingrédient',
      icon: Icons.eco_outlined,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!creating) ...[
              Text('Ingrédient', style: AppTextStyles.caption),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final ing in _existing)
                  ChoiceChip(
                    label: Text('${ing.name} · ${ing.costPerUnit} F/${ing.unit}'),
                    selected: _selected?.id == ing.id,
                    onSelected: (_) => setState(() {
                      _selected = ing;
                      _err = null;
                    }),
                  ),
              ]),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: () => setState(() {
                    _new = true;
                    _selected = null;
                    _err = null;
                  }),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Nouvel ingrédient'),
                ),
              ),
            ],
            if (creating) ...[
              TextField(
                controller: _nameCtrl,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                decoration:
                    const InputDecoration(labelText: 'Nom de l\'ingrédient'),
              ),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _unitCtrl,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                        labelText: 'Unité', hintText: 'g, kg, L, pièce'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _costCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration:
                        const InputDecoration(labelText: 'Coût / unité (F)'),
                  ),
                ),
              ]),
              if (_existing.isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => setState(() {
                      _new = false;
                      _err = null;
                    }),
                    child: const Text('← Choisir un ingrédient existant'),
                  ),
                ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _qtyCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Quantité utilisée par plat',
                suffixText: suffix,
              ),
            ),
            if (_err != null) ...[
              const SizedBox(height: 8),
              Text(_err!,
                  style: AppTextStyles.caption.copyWith(color: sem.danger)),
            ],
            const SizedBox(height: 18),
            AppPrimaryButton(
              label: 'Ajouter',
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
