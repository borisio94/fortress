import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/services/activity_service.dart';
import '../../../../core/services/dish_cost_service.dart';
import '../../../../core/services/ingredient_allocation_service.dart';
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
import '../../domain/entities/ingredient.dart';
import '../../domain/entities/recipe_ingredient.dart';
import '../../domain/entities/restaurant_activity.dart';

/// Ouvre la feuille de saisie d'un plat. Retourne `true` si un plat a été
/// créé ou modifié.
///
/// [requireIngredient] n'est posé que par le parcours de MISE EN ROUTE : il y
/// faut un plat composé pour que le module finances ait quelque chose à
/// calculer. Partout ailleurs il reste à `false`, sans quoi une bière ou une
/// bouteille d'eau — qui n'ont aucun ingrédient — deviendraient impossibles à
/// créer.
Future<bool?> showDishForm({
  required BuildContext context,
  required String shopId,
  Product? existing,
  bool requireIngredient = false,
}) =>
    showAdaptiveFormSheet<bool>(
      context: context,
      builder: (_) => DishFormSheet(
          shopId: shopId,
          existing: existing,
          requireIngredient: requireIngredient),
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

  /// Exige au moins un ingrédient coché (cf. [showDishForm]).
  final bool requireIngredient;

  const DishFormSheet({
    super.key,
    required this.shopId,
    this.existing,
    this.requireIngredient = false,
  });

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


  /// GROUPES D'ACCOMPAGNEMENTS propres à ce plat.
  ///
  /// « Riz → Sauce (obligatoire) → Viande (obligatoire) » : chaque groupe
  /// impose un choix, et chaque option pointe un plat de la carte, ce qui lui
  /// donne un vrai coût matières. Persistés à l'enregistrement seulement, avec
  /// le productId — définitif après la création du plat.

  /// Brouillon de composition (persisté en base seulement au save, avec le
  /// productId — définitif après la création du plat).
  final List<_RecipeDraft> _recipe = [];

  /// Catalogue d'ingrédients de la boutique, à cocher. Mutable : créer un
  /// ingrédient depuis cette feuille l'y ajoute sans rechargement.
  late final List<Ingredient> _catalog =
      IngredientService.forShop(widget.shopId);

  /// Coût matières du mois en cours, selon la méthode active de la boutique —
  /// sert à montrer ce que le plat coûte aujourd'hui. Lu UNE fois à
  /// l'ouverture : c'est une photo du mois.
  late final AllocationResult _allocation =
      DishCostService.forMonth(widget.shopId, DateTime.now());

  /// Méthode active — pilote l'affichage de la colonne des quantités dans
  /// l'éditeur de recette : demander une quantité que rien ne lit serait une
  /// saisie pour rien.
  late final DishCostMethod _costMethod =
      DishCostService.methodFor(widget.shopId);

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
        // Charge la composition existante.
        for (final line in RecipeService.forProduct(widget.shopId, pid)) {
          final ing = IngredientService.byId(widget.shopId, line.ingredientId);
          _recipe.add(_RecipeDraft(
            ingredientId: line.ingredientId,
            name: ing?.name ?? '(ingrédient supprimé)',
            portionWeight: line.portionWeight,
            unit: ing?.unit ?? '',
            initialQty: line.quantity,
            // Quantité héritée d'avant le retour de la fiche technique :
            // pré-remplie comme suggestion, mais signalée tant qu'elle n'est
            // pas relue. Elle ne compte dans aucun calcul d'ici là.
            inheritedUnconfirmed:
                line.quantity > 0 && !line.quantityConfirmed,
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
    // Un contrôleur par ligne de recette (quantité) : ils sont créés avec le
    // brouillon, ils meurent avec lui.
    for (final d in _recipe) {
      d.qty.dispose();
    }
    super.dispose();
  }

  List<String> get _categories =>
      LocalStorageService.getCategories(widget.shopId)..sort();

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
    // Parcours de mise en route uniquement : un plat composé est ce qui donne
    // au module finances quelque chose à calculer. Le bouton est déjà
    // désactivé dans ce cas — ce garde-fou couvre le chemin programmatique.
    if (widget.requireIngredient && _recipe.isEmpty) {
      setState(() =>
          _error = 'Ajoutez au moins 1 ingrédient pour continuer.');
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

  // ── Composition du plat ────────────────────────────────────────────────

  /// Aligne les liens persistés sur le brouillon `_recipe` : (ré)écrit les
  /// présents, supprime ceux décochés.
  Future<void> _syncRecipeLines(String productId) async {
    final currentIds = _recipe.map((d) => d.ingredientId).toSet();
    for (final line in RecipeService.forProduct(widget.shopId, productId)) {
      if (!currentIds.contains(line.ingredientId)) {
        await RecipeService.removeLine(line);
      }
    }
    final sheetMode = _costMethod == DishCostMethod.technicalSheet;
    for (final d in _recipe) {
      await RecipeService.addLink(
        shopId: widget.shopId,
        productId: productId,
        ingredientId: d.ingredientId,
        portionWeight: d.portionWeight,
        // Quantités écrites SEULEMENT quand la fiche technique est active :
        // en répartition le champ n'est pas affiché, et passer 0 effacerait
        // les fiches déjà pesées de quelqu'un qui bascule un instant de
        // méthode. `null` = « ne touche pas ».
        quantity: sheetMode ? d.qtyValue : null,
        unit: sheetMode ? d.unit : null,
        // Passer par le formulaire en mode fiche VAUT confirmation : la
        // valeur a été affichée, relue, et validée par l'enregistrement.
        quantityConfirmed: sheetMode ? d.qtyValue > 0 : null,
      );
    }
  }

  /// Coût matières du plat sur le MOIS EN COURS, tel que la répartition
  /// l'impute aujourd'hui.
  ///
  /// Ce n'est pas une propriété du plat : c'est le résultat des achats et des
  /// ventes du mois. Il changera le mois prochain, et c'est normal — l'écran le
  /// dit explicitement plutôt que de laisser croire à un coût figé.
  ///
  /// Recalculé à la demande (et non mémorisé) : cocher un ingrédient change
  /// immédiatement le dénominateur de la répartition.
  double get _allocatedCost {
    final pid = widget.existing?.id;
    if (pid == null) return 0;
    return _allocation.forProduct(pid);
  }

  /// Bascule un ingrédient dans la composition du plat.
  void _toggleIngredient(Ingredient ing) {
    setState(() {
      final at = _recipe.indexWhere((d) => d.ingredientId == ing.id);
      if (at >= 0) {
        _recipe.removeAt(at).qty.dispose();
      } else {
        _recipe.add(_RecipeDraft(
          ingredientId: ing.id,
          name: ing.name,
          portionWeight: RecipeIngredient.normalPortion,
          unit: ing.unit,
        ));
      }
    });
  }

  /// Crée un ingrédient sans quitter la fiche du plat, et l'y ajoute.
  Future<void> _createIngredientInline() async {
    final ing = await showAdaptiveFormSheet<Ingredient>(
      context: context,
      builder: (_) => _QuickIngredientSheet(shopId: widget.shopId),
    );
    if (ing == null || !mounted) return;
    setState(() {
      _catalog.add(ing);
      _catalog.sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      _recipe.add(_RecipeDraft(
        ingredientId: ing.id,
        name: ing.name,
        portionWeight: RecipeIngredient.normalPortion,
      ));
    });
  }

  /// Vide la fiche recette du plat.
  ///
  /// Comme tout le reste du formulaire, c'est un changement de BROUILLON : il
  /// n'est appliqué en base qu'à l'enregistrement (`_syncRecipeLines` retire
  /// alors les lignes absentes du brouillon). Fermer sans enregistrer ne perd
  /// donc rien — et `removeLine` remet au passage les ingrédients concernés en
  /// « spécialisé » s'ils ne servent plus qu'à un seul plat.
  Future<void> _clearRecipe() async {
    final n = _recipe.length;
    final confirmed = await AppConfirmDialog.show(
      context: context,
      icon: Icons.delete_sweep_outlined,
      iconColor: Theme.of(context).semantic.danger,
      title: 'Supprimer la fiche recette ?',
      body: Text(
        n > 1
            ? 'Les $n ingrédients seront retirés de ce plat.\n\n'
                'Le coût matières ne sera plus calculé et la vente ne '
                'décrémentera plus leur stock. Les ingrédients eux-mêmes '
                'restent dans votre catalogue.'
            : 'L\'ingrédient sera retiré de ce plat.\n\n'
                'Le coût matières ne sera plus calculé et la vente ne '
                'décrémentera plus son stock. L\'ingrédient lui-même reste '
                'dans votre catalogue.',
      ),
      cancelLabel: 'Annuler',
      confirmLabel: 'Supprimer',
      onConfirm: () {},
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      for (final d in _recipe) {
        d.qty.dispose();
      }
      _recipe.clear();
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

  /// Sélecteur de photo du plat. Extrait du `build` pour être posé soit à
  /// gauche des champs (écran large), soit centré au-dessus (écran étroit).
  /// [height] : la vignette est nettement plus haute à côté des champs
  /// (écran large) qu'empilée au-dessus d'eux — sinon elle laissait une bande
  /// vide sous elle, la colonne de droite étant bien plus haute.
  Widget _photoPicker(BuildContext context, {double height = 160}) {
    final theme = Theme.of(context);
    final sem = theme.semantic;
    final cs = theme.colorScheme;
    return InkWell(
                onTap: _pickImage,
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  width: 190,
                  height: height,
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
    );
  }

  /// Champs d'identité du plat : nom, catégorie, secteur, prix. Extraits pour
  /// pouvoir être rendus à droite de la photo.
  List<Widget> _identityFields(BuildContext context) {
    return [
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
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem = theme.semantic;
    final cs = theme.colorScheme;

    return AdaptiveFormFrame(
      title: _isEdit ? 'Modifier le plat' : 'Nouveau plat',
      icon: Icons.restaurant_rounded,
      iconColor: AppColors.primary,
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ══ BLOC 1 — identité du plat ═════════════════════════════
            // Photo à gauche, nom / catégorie / secteur / prix à droite.
            // Sous 560 px de large la colonne de droite deviendrait
            // illisible : on empile alors comme avant.
            LayoutBuilder(builder: (_, c) {
              final side = c.maxWidth >= 560;
              final photo = _photoPicker(context, height: side ? 210 : 160);
              final fields = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: _identityFields(context),
              );
              if (!side) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(child: photo),
                    const SizedBox(height: 18),
                    fields,
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  photo,
                  const SizedBox(width: 16),
                  Expanded(child: fields),
                ],
              );
            }),

            // ══ BLOC 2 — description et réglages ══════════════════════
            const SizedBox(height: 22),
            Divider(height: 1, color: sem.borderSubtle),
            const SizedBox(height: 18),

            // ── Description ──────────────────────────────────────────
            const AppFieldLabel('Description'),
            const SizedBox(height: 8),
            AppField(
              controller: _descCtrl,
              hint: 'Poulet, plantain, légumes sautés…',
              maxLines: 2,
            ),

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

            // ── Composition du plat ──────────────────────────────────────
            const SizedBox(height: 20),
            Row(children: [
              Icon(Icons.receipt_long_outlined,
                  size: 18, color: AppColors.primary),
              const SizedBox(width: 8),
              Expanded(
                // Même échelon que l'en-tête « Plus de réglages » juste
                // au-dessus : ce sont deux sections de même niveau dans la
                // même feuille, elles ne doivent pas avoir deux tailles.
                child: Text('Composition',
                    style: AppTextStyles.bodySmBold
                        .copyWith(color: cs.onSurface)),
              ),
              TextButton.icon(
                onPressed: _createIngredientInline,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('Nouvel ingrédient'),
              ),
            ]),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                  'Cochez ce que ce plat contient. Aucune quantité à saisir : '
                  'le coût de chaque ingrédient est réparti entre les plats '
                  'qui le portent, au prorata de ce qui se vend.',
                  style: AppTextStyles.caption),
            ),
            // Mise en route : on dit POURQUOI c'est exigé plutôt que de
            // laisser un bouton grisé sans explication.
            if (widget.requireIngredient && _recipe.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                    'Ajoutez au moins 1 ingrédient pour continuer — c\'est ce '
                    'lien qui permettra de calculer votre marge.',
                    style:
                        AppTextStyles.caption.copyWith(color: sem.warning)),
              ),
            if (_catalog.isEmpty)
              Text(
                  'Aucun ingrédient dans votre catalogue. Créez-en un pour '
                  'commencer à suivre le coût de ce plat.',
                  style: AppTextStyles.captionHint)
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final ing in _catalog)
                    _Chip(
                      label: ing.name,
                      selected:
                          _recipe.any((d) => d.ingredientId == ing.id),
                      onTap: () => _toggleIngredient(ing),
                    ),
                ],
              ),
            if (_recipe.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(
                  _costMethod == DishCostMethod.technicalSheet
                      ? 'Quantités par portion'
                      : 'Générosité des portions',
                  style: AppTextStyles.caption),
              const SizedBox(height: 2),
              Text(
                  _costMethod == DishCostMethod.technicalSheet
                      ? 'Ce que contient UNE assiette, dans l\'unité de '
                          'chaque ingrédient. Une seule quantité manquante et '
                          'le plat sort du calcul théorique — mieux vaut ça '
                          'qu\'un coût sous-évalué et crédible.'
                      : 'Laissez « Normale » sauf si ce plat en contient '
                          'nettement plus ou moins que vos autres plats.',
                  style: AppTextStyles.captionHint),
              const SizedBox(height: 8),
              for (final d in _recipe)
                _PortionRow(
                  draft: d,
                  sheetMode: _costMethod == DishCostMethod.technicalSheet,
                  onChanged: (w) =>
                      setState(() => d.portionWeight = w),
                  // Toucher au champ vaut relecture : l'avertissement de
                  // quantité héritée tombe dès la première frappe.
                  onQtyChanged: () {
                    if (d.inheritedUnconfirmed) {
                      setState(() => d.inheritedUnconfirmed = false);
                    }
                  },
                  onRemove: () => setState(() {
                    _recipe.remove(d);
                    d.qty.dispose();
                  }),
                ),
              const SizedBox(height: 10),
              _RecipeSummary(
                cost: _allocatedCost,
                price: double.tryParse(
                        _priceCtrl.text.trim().replaceAll(',', '.')) ??
                    0,
                isNewDish: !_isEdit,
              ),
              // Tout décocher d'un coup — le ✕ de chaque ligne reste la voie
              // normale pour en retirer UN.
              Center(
                child: TextButton.icon(
                  onPressed: _saving ? null : _clearRecipe,
                  icon: Icon(Icons.delete_sweep_outlined,
                      size: 18, color: sem.danger),
                  label: Text('Vider la composition',
                      style: AppTextStyles.label.copyWith(color: sem.danger)),
                ),
              ),
            ],

            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!,
                  style:
                      AppTextStyles.caption.copyWith(color: sem.danger)),
            ],
            const SizedBox(height: 20),
            // Enregistrer et Supprimer sur la MÊME ligne. « Supprimer » reste
            // secondaire — contour rouge et non aplat — pour qu'une action
            // destructive ne se présente pas comme l'action attendue.
            Row(children: [
              Expanded(
                flex: 2,
                child: AppPrimaryButton(
                  label: _isEdit ? 'Enregistrer' : 'Créer le plat',
                  icon: Icons.check_rounded,
                  fullWidth: true,
                  isLoading: _saving,
                  enabled: !widget.requireIngredient || _recipe.isNotEmpty,
                  onTap: _submit,
                ),
              ),
              if (_isEdit) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _saving ? null : _deleteDish,
                    icon: Icon(Icons.delete_outline_rounded,
                        size: 18, color: sem.danger),
                    label: Text('Supprimer',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            AppTextStyles.label.copyWith(color: sem.danger)),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 46),
                      side: BorderSide(
                          color: sem.danger.withValues(alpha: 0.5)),
                    ),
                  ),
                ),
              ],
            ]),
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
//  COMPOSITION DU PLAT
//
//  Aucune quantité n'est saisie : on coche les ingrédients, et le coût de
//  chacun est réparti entre les plats qui le portent au prorata des ventes
//  (cf. `IngredientAllocationService`). Le poids de portion ne sert qu'à dire
//  qu'une part est plus généreuse qu'une autre.
// ═══════════════════════════════════════════════════════════════════════

/// Lien plat ↔ ingrédient en cours d'édition (non encore persisté).
///
/// Mutable sur [portionWeight] seul : c'est la seule chose que l'écran fait
/// varier, et recréer l'objet à chaque tap ferait perdre l'ordre de la liste.
class _RecipeDraft {
  final String ingredientId;
  final String name;
  double portionWeight;

  /// Unité de l'INGRÉDIENT — jamais choisie ici. Le module ne convertit pas
  /// les unités : la quantité de recette s'exprime forcément dans celle de
  /// l'ingrédient, et l'écran l'affiche en dur à côté du champ.
  final String unit;

  /// Quantité par portion (fiche technique). Vide = non renseignée.
  final TextEditingController qty;

  /// La valeur pré-remplie vient-elle d'une saisie ANCIENNE, jamais relue ?
  /// Elle s'affiche alors en avertissement tant qu'on ne l'a pas retouchée ou
  /// confirmée — cf. `RecipeIngredient.quantityConfirmed`.
  bool inheritedUnconfirmed;

  _RecipeDraft({
    required this.ingredientId,
    required this.name,
    required this.portionWeight,
    this.unit = '',
    double initialQty = 0,
    this.inheritedUnconfirmed = false,
  }) : qty = TextEditingController(
            text: initialQty > 0 ? _trimZeros(initialQty) : '');

  double get qtyValue =>
      double.tryParse(qty.text.trim().replaceAll(',', '.')) ?? 0;

  static String _trimZeros(double v) {
    final s = v.toStringAsFixed(3);
    return s.contains('.')
        ? s.replaceFirst(RegExp(r'\.?0+$'), '')
        : s;
  }
}

/// Une ligne de composition.
///
/// Son contenu dépend de la MÉTHODE DE COÛT active, et c'est voulu :
///   * **répartition** — générosité de la portion (petite · normale · grande).
///     Aucune quantité n'est demandée, c'est le principe même de la méthode ;
///   * **fiche technique** — quantité par portion, dans l'unité de
///     l'ingrédient. Les pastilles de générosité disparaissent : elles ne
///     servent qu'à la répartition, et les laisser laisserait croire qu'elles
///     pondèrent aussi la fiche.
///
/// Afficher les deux ensemble ferait saisir deux fois la même intention sous
/// deux formes, dont une seule compte.
class _PortionRow extends StatelessWidget {
  final _RecipeDraft draft;
  final ValueChanged<double> onChanged;
  final VoidCallback onRemove;
  final bool sheetMode;
  final VoidCallback onQtyChanged;

  const _PortionRow({
    required this.draft,
    required this.onChanged,
    required this.onRemove,
    required this.sheetMode,
    required this.onQtyChanged,
  });

  static const _options = <({double weight, String label})>[
    (weight: RecipeIngredient.smallPortion, label: 'Petite'),
    (weight: RecipeIngredient.normalPortion, label: 'Normale'),
    (weight: RecipeIngredient.largePortion, label: 'Grande'),
  ];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    // Une quantité héritée jamais relue : signalée tant qu'on n'y a pas
    // touché. Elle ne compte dans aucun calcul avant confirmation.
    final warn = sheetMode && draft.inheritedUnconfirmed;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text(draft.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.bodySm.copyWith(color: cs.onSurface)),
            ),
            if (sheetMode) ...[
              SizedBox(
                width: 96,
                child: TextField(
                  controller: draft.qty,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  textAlign: TextAlign.end,
                  style: AppTextStyles.input,
                  onChanged: (_) => onQtyChanged(),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '0',
                    hintStyle: AppTextStyles.inputHint,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 8),
                    // Unité IMPOSÉE, jamais choisie : le module ne convertit
                    // pas, et « kg » dosé en grammes ferait un coût faux d'un
                    // facteur mille.
                    suffixText:
                        draft.unit.isEmpty ? null : ' ${draft.unit}',
                    suffixStyle: AppTextStyles.caption,
                  ),
                ),
              ),
            ] else
              for (final o in _options) ...[
                _Chip(
                  label: o.label,
                  selected: (draft.portionWeight - o.weight).abs() < 0.01,
                  onTap: () => onChanged(o.weight),
                ),
                const SizedBox(width: 6),
              ],
            IconButton(
              onPressed: onRemove,
              visualDensity: VisualDensity.compact,
              tooltip: 'Retirer',
              icon: Icon(Icons.close_rounded, size: 18, color: sem.danger),
            ),
          ]),
          if (warn)
            Padding(
              padding: const EdgeInsets.only(left: 2, top: 2),
              child: Text(
                  'Quantité saisie avant le retour de la fiche technique — '
                  'vérifiez-la, elle ne compte pas encore.',
                  style: AppTextStyles.micro
                      .copyWith(color: sem.warningText)),
            ),
        ],
      ),
    );
  }
}

/// Bloc récapitulatif : coût matières du MOIS · prix de vente · marge.
///
/// Le coût affiché n'est pas une propriété du plat mais le résultat des achats
/// et des ventes du mois en cours. Le dire est indispensable : sans cette
/// mention, un gérant croirait à un chiffre figé et s'inquiéterait de le voir
/// bouger le mois suivant.
class _RecipeSummary extends StatelessWidget {
  final double cost;
  final double price;

  /// Un plat pas encore créé n'a aucune vente : rien à répartir sur lui.
  final bool isNewDish;

  const _RecipeSummary({
    required this.cost,
    required this.price,
    this.isNewDish = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    final margin = price - cost;
    final pct = price <= 0 ? 0.0 : (margin / price) * 100;
    final accent = margin >= 0 ? sem.success : sem.danger;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: sem.borderSubtle),
      ),
      child: Column(children: [
        if (isNewDish)
          Text(
              'Le coût matières apparaîtra ici une fois le plat créé et des '
              'ventes enregistrées : il se déduit de vos achats du mois.',
              style: AppTextStyles.captionHint)
        else if (cost <= 0)
          Text(
              'Aucun coût imputé ce mois-ci : rattachez vos achats à ces '
              'ingrédients dans Finances → Dépenses, et vendez ce plat au '
              'moins une fois.',
              style: AppTextStyles.captionHint)
        else ...[
          _line(context, 'Coût matières (ce mois)',
              CurrencyFormatter.format(cost)),
          _line(context, 'Prix de vente', CurrencyFormatter.format(price)),
          Divider(height: 16, color: sem.borderSubtle),
          _line(context, 'Marge', CurrencyFormatter.format(margin),
              color: accent, bold: true),
          _line(context, 'Marge %', '${pct.toStringAsFixed(0)} %',
              color: accent),
          const SizedBox(height: 6),
          Text(
              'Calculé sur les achats et les ventes du mois en cours — ce '
              'chiffre évolue avec eux.',
              style: AppTextStyles.captionHint),
        ],
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

/// Création rapide d'un ingrédient sans quitter la fiche du plat.
///
/// Volontairement minimale : nom et unité. Le coût ne se saisit PAS ici — il
/// vient des achats rattachés à l'ingrédient, pas d'un prix théorique tapé une
/// fois pour toutes.
class _QuickIngredientSheet extends StatefulWidget {
  final String shopId;
  const _QuickIngredientSheet({required this.shopId});
  @override
  State<_QuickIngredientSheet> createState() => _QuickIngredientSheetState();
}

class _QuickIngredientSheetState extends State<_QuickIngredientSheet> {
  final _nameCtrl = TextEditingController();
  String _unit = 'kg';
  String? _err;
  bool _saving = false;

  static const _units = ['kg', 'g', 'L', 'pièce', 'boîte', 'sac', 'tas'];

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _err = 'Nom requis');
      return;
    }
    setState(() => _saving = true);
    try {
      final ing = await IngredientService.create(
        shopId: widget.shopId,
        name: name,
        unit: _unit,
      );
      if (mounted) Navigator.of(context).pop(ing);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _err = 'Création impossible : $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return AdaptiveFormFrame(
      title: 'Nouvel ingrédient',
      icon: Icons.eco_outlined,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _nameCtrl,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                  labelText: 'Nom', hintText: 'Poulet, huile rouge, riz…'),
            ),
            const SizedBox(height: 12),
            Text('Unité d\'achat', style: AppTextStyles.caption),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final u in _units)
                  _Chip(
                    label: u,
                    selected: _unit == u,
                    onTap: () => setState(() => _unit = u),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
                'Le coût viendra de vos achats : saisissez-les dans '
                'Finances → Dépenses en les rattachant à cet ingrédient, ou '
                'via le bouton Réception.',
                style: AppTextStyles.captionHint),
            if (_err != null) ...[
              const SizedBox(height: 8),
              Text(_err!,
                  style: AppTextStyles.caption.copyWith(color: sem.danger)),
            ],
            const SizedBox(height: 18),
            AppPrimaryButton(
              label: 'Créer et ajouter',
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
