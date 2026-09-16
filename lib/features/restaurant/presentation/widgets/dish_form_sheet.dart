import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/services/activity_service.dart';
import '../../../../core/services/daily_expense_service.dart';
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
import '../../../../core/utils/name_key.dart';
import '../../../../features/inventaire/domain/entities/product.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_field.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../../../shared/widgets/app_select_menu.dart';
import 'cost_method_picker.dart';
import '../../../../shared/widgets/app_confirm_dialog.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/product_image_card.dart';
import '../../domain/entities/daily_expense.dart';
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

/// Côté de la vignette photo. Carré : une photo de plat se cadre au centre, et
/// un carré ne laisse pas croire qu'on attend une image en paysage.
const double _kPhotoTile = 88;

/// Placeholder du formulaire, remonté d'un cran de contraste.
///
/// `AppTextStyles.inputHint` est en `textHint`, qui vaut `slate-500` en mode
/// sombre : sur le fond d'une feuille, « Poulet DG » et « 3500 » se lisaient
/// comme un champ désactivé — on n'ose pas écrire dans un champ qui a l'air
/// éteint. Getter et non constante : la couleur est adaptative clair/sombre.
TextStyle get _kHintStyle =>
    AppTextStyles.inputHint.copyWith(color: AppColors.textSecondary);

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

  /// Y a-t-il au moins un ingrédient chiffré à la FICHE TECHNIQUE dans cette
  /// recette ? Pilote le titre de la section. La colonne des quantités, elle,
  /// s'affiche ligne par ligne : demander une quantité pour un ingrédient
  /// réparti serait une saisie que rien ne lit.
  bool get _hasSheetLine => _recipe.any((d) => d.usesSheet);

  int _rating = 0;
  // Décoché par défaut, à l'inverse du défaut global : un plat est produit à
  // la commande. L'activer d'office ramènerait les stocks négatifs et le
  // bruit dans le journal que `track_stock` a précisément corrigés.
  bool _trackStock = false;
  bool _isActive = true;

  /// Publication sur la vitrine publique de l'établissement.
  ///
  /// CHAMP À PART, et non plus la recopie de `_isActive`. Enregistrer un plat
  /// publiait sa photo, son nom et son prix sur une page accessible à tous,
  /// alors que le seul interrupteur du formulaire disait « Disponible à la
  /// vente » et parlait de la carte. Personne ne choisissait : c'était un effet
  /// de bord, et il se réappliquait à chaque enregistrement.
  ///
  /// Le défaut reste « publié » : la vitrine-menu existe (la page publique a un
  /// rendu dédié aux établissements de restauration) et les cartes déjà en
  /// ligne ne doivent pas disparaître parce qu'on a rendu le choix visible.
  bool _isVisibleWeb = true;
  bool _advanced = false;

  /// Identifiant du plat EN COURS de création, conservé d'une tentative
  /// d'enregistrement à l'autre.
  ///
  /// Il était recalculé à chaque appel (`'prod_${DateTime.now()...}'`). Après un
  /// échec partiel — le plat écrit, la recette non — le formulaire restait
  /// ouvert : ré-appuyer sur Enregistrer créait donc un SECOND plat au lieu de
  /// réparer le premier. C'est ainsi que le formulaire fabriquait lui-même les
  /// doublons qui faussent la répartition du coût.
  String? _newProductId;

  /// Nom du plat DÉJÀ à la carte qui porte le même nom que celui en cours de
  /// saisie, `null` s'il n'y en a pas.
  ///
  /// AVERTISSEMENT et non blocage : deux plats homonymes sont parfois
  /// légitimes — la même préparation en entrée et en plat, une déclinaison
  /// qu'on n'a pas su nommer autrement. Mais c'est presque toujours une
  /// inattention, et elle coûte cher : les ventes se répartissent entre deux
  /// fiches, les rapports affichent deux lignes pour le même plat, et si l'une
  /// des deux n'a pas de recette, le coût de ses ingrédients se reporte sur
  /// l'autre.
  ///
  /// Contrôle LOCAL, sur le nom. `AppDatabase.saveProduct` en a bien un, mais
  /// il est hors d'atteinte ici : sa partie « nom » exige le réseau (deux
  /// requêtes) et sa partie locale ne regarde que les SKU — or un plat n'en a
  /// pas. D'où `skipValidation: true` à l'enregistrement, qui reste justifié.
  String? _dupName;

  /// Ingrédients créés DEPUIS CE FORMULAIRE et dont la création a écrit un
  /// achat en comptabilité.
  ///
  /// Créer un ingrédient avec un montant payé écrit une dépense sur-le-champ,
  /// avant même que le plat n'existe. Abandonner ensuite le formulaire laissait
  /// cette dépense rattachée à un ingrédient qui n'entre dans aucune recette :
  /// la répartition ne trouve aucune assiette pour l'absorber, le montant part
  /// dans `unallocated` et gonfle le food cost de l'établissement sans jamais
  /// apparaître dans la marge d'un plat — donc sans que rien ne le signale.
  ///
  /// On ne les supprime PAS d'office : l'achat peut être réel, facture en main,
  /// et le supprimer parce que l'utilisateur a renoncé au plat lui ferait
  /// ressaisir une dépense qu'il a bel et bien engagée. C'est lui qui trancherait
  /// à la fermeture.
  ///
  /// Les CATÉGORIES et les UNITÉS créées en route ne sont pas suivies : elles ne
  /// portent aucun montant, n'entrent dans aucun calcul, et une catégorie sans
  /// plat n'apparaît même pas sur la carte (`_categories` ne liste que celles
  /// portées par un plat). Les annuler coûterait du code pour rien.
  final List<Ingredient> _purchasedIngredients = [];

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
      _isVisibleWeb = p.isVisibleWeb;
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
            usesSheet: ing?.usesTechnicalSheet ?? false,
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
    _nameCtrl.addListener(_onNameChanged);
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

  /// Recherche d'un homonyme à chaque frappe.
  ///
  /// Pas d'anti-rebond, contrairement au contrôle de SKU de l'inventaire
  /// e-commerce : celui-là interroge le réseau, celui-ci parcourt une liste
  /// déjà en mémoire (cache produits de `LocalStorageService`).
  void _onNameChanged() {
    final dup = _findDuplicateName(_nameCtrl.text);
    if (dup != _dupName) setState(() => _dupName = dup);
  }

  /// Le nom d'un plat existant identique à [raw], ou `null`.
  ///
  /// Renvoie le nom TEL QU'IL EST ÉCRIT dans la carte : « POULET dg » doit
  /// pouvoir répondre « Poulet DG », sinon l'avertissement paraît absurde.
  /// La comparaison est celle de `nameKey` : insensible à la casse, aux accents
  /// et aux espaces en trop. Les plats SUPPRIMÉS sont hors-jeu —
  /// `getProductsForShop` les exclut — car reprendre le nom d'un plat retiré du
  /// catalogue est légitime.
  String? _findDuplicateName(String raw) {
    final key = nameKey(raw);
    if (key.isEmpty) return null;
    final selfId = widget.existing?.id;
    for (final p in LocalStorageService.getProductsForShop(widget.shopId)) {
      if (p.id != null && p.id == selfId) continue;
      if (nameKey(p.name) == key) return p.name;
    }
    return null;
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
      // `??=` : le premier essai fixe l'identifiant, les suivants le reprennent
      // — une reprise après erreur RÉÉCRIT le même plat.
      final productId = existing?.id ?? (_newProductId ??= 'prod_$ts');
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
        isVisibleWeb: _isVisibleWeb,
        trackStock: _trackStock,
        activityId: _activityId,
        rating: _rating,
        imageUrl: existing?.imageUrl,
        variants: [variant],
        createdAt: existing?.createdAt ?? DateTime.now(),
      );

      await AppDatabase.saveProduct(product, skipValidation: true);

      // ══ À PARTIR D'ICI, LE PLAT EXISTE EN BASE ════════════════════════
      // Tout ce qui suit doit donc échouer SANS emporter l'enregistrement :
      // laisser remonter une exception rendait la main sur un formulaire
      // ouvert, alors que le plat était déjà écrit — sans sa recette, donc
      // chiffré à zéro et faussant la répartition du coût des ingrédients.

      if (_imageBytes != null) {
        // La photo est un ORNEMENT : `enqueue` écrit dans Hive sans filet
        // (`box.add` nu, avec les octets de l'image dedans). Une box pleine ou
        // fermée faisait perdre la recette d'un plat, pour une vignette.
        try {
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
        } catch (e) {
          debugPrint('[DishForm] photo non mise en file : $e');
        }
      }

      final recipeSaved = await _trySyncRecipeLines(productId);
      if (!mounted) return;
      if (!recipeSaved) {
        // Le plat est CONSERVÉ : la saisie ne doit pas être perdue, et le plat
        // se rouvre pour compléter sa recette. Mais on le dit — sans recette il
        // est chiffré à zéro, sa marge paraît excellente, et le coût de ses
        // ingrédients se reporte sur les autres plats qui les portent.
        AppSnack.warning(
            context,
            'Plat créé, mais sa recette n\'a pas pu être enregistrée. '
            'Rouvrez-le pour la compléter.');
      }
      // Le plat existe : les ingrédients créés en cours de route ne sont plus
      // orphelins, leurs achats sont désormais rattachés à une recette.
      _purchasedIngredients.clear();
      Navigator.of(context).pop(true);
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

  /// Écrit la recette, avec UN réessai.
  ///
  /// Renvoie `false` si les deux tentatives échouent. `_syncRecipeLines` est
  /// idempotent — `addLink` met à jour la ligne existante au lieu d'en créer une
  /// seconde — donc rejouer ne peut pas doubler une composition.
  ///
  /// Un seul réessai, pas une boucle : ce qui peut échouer ici est une écriture
  /// Hive locale. Si elle échoue deux fois de suite, insister ne changera rien
  /// et fera attendre quelqu'un en plein service.
  Future<bool> _trySyncRecipeLines(String productId) async {
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        await _syncRecipeLines(productId);
        return true;
      } catch (e) {
        debugPrint('[DishForm] recette, tentative $attempt : $e');
      }
    }
    return false;
  }

  /// Aligne les liens persistés sur le brouillon `_recipe` : (ré)écrit les
  /// présents, supprime ceux décochés.
  Future<void> _syncRecipeLines(String productId) async {
    final currentIds = _recipe.map((d) => d.ingredientId).toSet();
    for (final line in RecipeService.forProduct(widget.shopId, productId)) {
      if (!currentIds.contains(line.ingredientId)) {
        await RecipeService.removeLine(line);
      }
    }
    for (final d in _recipe) {
      await RecipeService.addLink(
        shopId: widget.shopId,
        productId: productId,
        ingredientId: d.ingredientId,
        portionWeight: d.portionWeight,
        // Quantités écrites SEULEMENT pour les ingrédients chiffrés à la
        // fiche : pour les autres le champ n'est pas affiché, et passer 0
        // effacerait une quantité déjà pesée si l'ingrédient repassait un
        // instant en répartition. `null` = « ne touche pas ».
        quantity: d.usesSheet ? d.qtyValue : null,
        unit: d.usesSheet ? d.unit : null,
        // Passer par le formulaire VAUT confirmation : la valeur a été
        // affichée, relue, et validée par l'enregistrement.
        quantityConfirmed: d.usesSheet ? d.qtyValue > 0 : null,
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
          usesSheet: ing.usesTechnicalSheet,
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
    // A-t-il coûté quelque chose ? La feuille de création écrit la dépense
    // elle-même ; on la relit plutôt que de faire remonter un second résultat,
    // et c'est la base qui fait foi.
    if (_purchasesFor(ing.id) > 0) _purchasedIngredients.add(ing);
    setState(() {
      _catalog.add(ing);
      _catalog.sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      _recipe.add(_RecipeDraft(
        ingredientId: ing.id,
        name: ing.name,
        portionWeight: RecipeIngredient.normalPortion,
        unit: ing.unit,
        usesSheet: ing.usesTechnicalSheet,
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
  /// Vignette photo — carré de [_kPhotoTile], bordure pointillée quand elle est
  /// vide.
  ///
  /// Elle occupait 190 px de large sur 210 de haut, soit le tiers de la feuille
  /// pour un ornement facultatif : le prix, lui, arrivait sous la ligne de
  /// flottaison. Réduite à une vignette, elle laisse la place aux deux champs
  /// obligatoires.
  ///
  /// Le POINTILLÉ dit « à remplir » sans écrire un mot de plus — un trait plein
  /// se lit comme un cadre vide, et c'est ainsi que la photo passait pour une
  /// image qui n'a pas chargé.
  Widget _photoPicker(BuildContext context) {
    final theme = Theme.of(context);
    final sem = theme.semantic;
    final cs = theme.colorScheme;
    final filled = _imageBytes != null || _existingImageUrl != null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: _pickImage,
          borderRadius: BorderRadius.circular(12),
          child: _DashedBorder(
            // Une fois la photo posée, le pointillé n'a plus rien à demander.
            enabled: !filled,
            color: sem.borderSubtle,
            radius: 12,
            child: Container(
              width: _kPhotoTile,
              height: _kPhotoTile,
              decoration: BoxDecoration(
                color: sem.trackMuted,
                borderRadius: BorderRadius.circular(12),
                border: filled
                    ? Border.all(color: sem.borderSubtle)
                    : null,
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
                      : Icon(Icons.photo_camera_outlined,
                          size: 24,
                          color: cs.onSurface.withValues(alpha: 0.45))),
            ),
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          width: _kPhotoTile,
          child: Text('Photo',
              textAlign: TextAlign.center,
              style: AppTextStyles.microSecondary),
        ),
      ],
    );
  }

  /// Les DEUX champs obligatoires du plat, et eux seuls : nom puis prix.
  ///
  /// La catégorie et le secteur les suivaient ici même. Le prix arrivait donc en
  /// quatrième position, alors que c'est — avec le nom — tout ce qu'il faut pour
  /// mettre un plat à la carte. La catégorie est descendue en pleine largeur
  /// sous ce bloc, le secteur dans le repli.
  List<Widget> _identityFields(BuildContext context) {
    return [
            // ── Nom ──────────────────────────────────────────────────
            const AppFieldLabel('Nom du plat', required: true),
            const SizedBox(height: 8),
            AppField(
              controller: _nameCtrl,
              hint: 'Poulet DG',
              hintStyle: _kHintStyle,
              autofocus: !_isEdit,
              prefixIcon: Icons.restaurant_rounded,
              // Le champ porte lui-même l'avertissement : un message qui flotte
              // sous un champ d'allure normale ne dit pas lequel il concerne.
              borderColor:
                  _dupName != null ? Theme.of(context).semantic.warning : null,
            ),
            if (_dupName != null) _DupNameNotice(name: _dupName!),
            const SizedBox(height: 16),

            // ── Prix de vente ────────────────────────────────────────
            // Juste sous le nom : avec lui, c'est tout ce qu'il faut pour
            // mettre un plat à la carte.
            const AppFieldLabel('Prix de vente', required: true),
            const SizedBox(height: 8),
            AppField(
              controller: _priceCtrl,
              hint: '3500',
              hintStyle: _kHintStyle,
              numbersOnly: true,
              keyboardType: TextInputType.number,
              prefixIcon: Icons.payments_outlined,
              suffixIcon: Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Text(CurrencyFormatter.currentSymbol,
                    style: AppTextStyles.bodySmSecondary),
              ),
            ),
    ];
  }

  /// Catégorie — sur toute la largeur, sous le bloc d'identité.
  ///
  /// Deux états, parce qu'un champ obligatoire et vide ne peut pas se contenter
  /// d'une puce « + Nouvelle » posée seule : rien ne disait qu'il fallait agir,
  /// ni que l'enregistrement serait refusé sans elle.
  Widget _categoryField(BuildContext context) {
    if (_categories.isEmpty) {
      return _InfoBanner(
        text: 'Aucune catégorie. Créez-en une pour ranger vos plats.',
        actionLabel: 'Nouvelle',
        onAction: _addCategory,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
            // Pointillée : elle n'est pas une catégorie de plus, elle en
            // fabrique une. Le trait discontinu suffit à le dire.
            _Chip(
              label: '+ Nouvelle',
              selected: false,
              dashed: true,
              onTap: _addCategory,
            ),
          ],
        ),
      ],
    );
  }

  /// Secteur d'activité — descendu dans le repli.
  ///
  /// Il était masqué en silence quand la boutique n'a aucune activité : on ne
  /// pouvait donc pas savoir que ce réglage existe, ni où le créer. Il annonce
  /// désormais où ça se passe.
  Widget _activityField(BuildContext context) {
    if (_activities.isEmpty) {
      return Text(
          'Aucun secteur défini. Ils se créent dans Finances → Activités, pour '
          'séparer les chiffres du bar et de la cuisine.',
          style: AppTextStyles.caption);
    }
    return Wrap(
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
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<bool>(
      // Bloqué UNIQUEMENT s'il y a un achat à trancher : le reste du temps la
      // feuille se ferme comme avant, au doigt comme au bouton retour.
      canPop: _purchasedIngredients.isEmpty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _resolveOrphanPurchases();
      },
      child: _buildForm(context),
    );
  }

  /// Que faire des achats écrits pour un plat qu'on n'enregistre pas ?
  ///
  /// Posé À LA FERMETURE et non à la création : au moment où l'ingrédient est
  /// créé, rien ne dit encore que le plat sera abandonné — et interrompre la
  /// saisie pour une question hypothétique serait pire que le défaut qu'on
  /// corrige.
  Future<void> _resolveOrphanPurchases() async {
    final total = _purchasedIngredients.fold<int>(
        0, (s, i) => s + _purchasesFor(i.id));
    final names = _purchasedIngredients.map((i) => i.name).join(', ');
    final many = _purchasedIngredients.length > 1;

    final keep = await AppConfirmDialog.show(
      context: context,
      icon: Icons.receipt_long_outlined,
      iconColor: Theme.of(context).semantic.warning,
      title: many ? 'Garder ces achats ?' : 'Garder cet achat ?',
      body: Text(
        'Vous avez enregistré ${CurrencyFormatter.format(total.toDouble())} '
        'd\'achat${many ? 's' : ''} pour $names, mais ce plat n\'a pas été '
        'créé.\n\n'
        'Gardez-${many ? 'les' : 'le'} si vous avez réellement payé : '
        '${many ? 'ils resteront' : 'il restera'} dans vos dépenses, en attente '
        'd\'un plat à chiffrer. Sinon ${many ? 'ils seront supprimés' : 'il sera '
        'supprimé'} avec ${many ? 'les ingrédients' : 'l\'ingrédient'}.',
      ),
      cancelLabel: 'Supprimer',
      confirmLabel: 'Garder',
      onConfirm: () {},
    );
    // `null` = la boîte a été fermée sans choisir : on reste dans le formulaire
    // plutôt que de décider à sa place.
    if (keep == null || !mounted) return;
    if (keep != true) await _discardOrphanPurchases();
    // Vidée dans les deux cas : la question a été posée, `canPop` laisse
    // désormais passer.
    _purchasedIngredients.clear();
    if (mounted) Navigator.of(context).pop(false);
  }

  /// Supprime les achats ET les ingrédients qui les portent.
  ///
  /// Les deux ensemble : garder un ingrédient sans achat le ferait remonter en
  /// orange dans la liste des ingrédients « sans dépense », pour une saisie que
  /// l'utilisateur vient justement d'annuler.
  Future<void> _discardOrphanPurchases() async {
    for (final ing in _purchasedIngredients) {
      for (final e in DailyExpenseService.forShop(widget.shopId)) {
        if (e.ingredientId == ing.id) {
          await DailyExpenseService.delete(e.id, widget.shopId);
        }
      }
      await IngredientService.delete(ing.id, widget.shopId);
    }
  }

  /// Total des achats déjà rattachés à cet ingrédient (FCFA).
  int _purchasesFor(String ingredientId) {
    var total = 0;
    for (final e in DailyExpenseService.forShop(widget.shopId)) {
      if (e.ingredientId == ingredientId) total += e.amount;
    }
    return total;
  }

  Widget _buildForm(BuildContext context) {
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
            // Vignette photo à gauche, les DEUX champs obligatoires à droite :
            // nom puis prix. Rien d'autre — la catégorie suit en pleine
            // largeur, le secteur est descendu dans le repli. Les deux champs
            // sans lesquels l'enregistrement est refusé tiennent ainsi dans le
            // premier regard.
            //
            // Le seuil de 560 px est conservé : sous cette largeur, une colonne
            // de champs à côté d'une vignette redevient trop étroite pour un
            // prix et un nom, et l'on empile.
            LayoutBuilder(builder: (_, c) {
              final side = c.maxWidth >= 560;
              final photo = _photoPicker(context);
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

            // ── Catégorie ────────────────────────────────────────────
            // Pleine largeur, sous le bloc : une liste de puces coincée dans
            // une demi-colonne se replie sur trois lignes dès la troisième
            // catégorie.
            const SizedBox(height: 16),
            _categoryField(context),

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
              hintStyle: _kHintStyle,
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
                    // Le titre DIT CE QU'IL CACHE. « Plus de réglages »
                    // n'annonçait rien : on l'ouvrait pour voir, ou jamais.
                    Text('Coût, stock et visibilité',
                        style: AppTextStyles.bodySmBold
                            .copyWith(color: cs.onSurface)),
                  ],
                ),
              ),
            ),
            // LISTE et non empilement de champs : chaque réglage porte son
            // titre en gras et son explication dessous, séparés par un filet.
            // En vrac, le coût matière — le moins important des cinq — était
            // le plus visible, parce que seul lui avait la forme d'un champ.
            if (_advanced) ...[
              const SizedBox(height: 4),
              _SettingTile(
                title: 'Coût matière',
                hint: 'Utilisé tant qu\'aucun ingrédient n\'est rattaché. '
                    'Le coût réel le remplacera dès vos premiers achats.',
                trailing: SizedBox(
                  width: 132,
                  child: AppField(
                    controller: _costCtrl,
                    hint: '0',
                    hintStyle: _kHintStyle,
                    numbersOnly: true,
                    isDense: true,
                    keyboardType: TextInputType.number,
                    suffixIcon: Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Text(CurrencyFormatter.currentSymbol,
                          style: AppTextStyles.bodySmSecondary),
                    ),
                  ),
                ),
              ),
              _SettingTile(
                title: 'Suivre le stock',
                hint: 'Pour les boissons en bouteille, pas pour un plat '
                    'cuisiné.',
                trailing: Switch(
                  value: _trackStock,
                  onChanged: (v) => setState(() => _trackStock = v),
                ),
              ),
              _SettingTile(
                title: 'Proposer à la vente',
                // Décrit le comportement RÉEL : le plat quitte la carte ET la
                // vitrine (la page publique filtre aussi sur ce drapeau), et il
                // se retrouve derrière le bandeau de l'écran Menu, nommé ici
                // exactement comme il s'affiche là-bas.
                hint: 'Décoché, le plat quitte la carte et la vitrine en '
                    'ligne. Il reste accessible depuis « plats retirés de la '
                    'vente », sur l\'écran Menu.',
                trailing: Switch(
                  value: _isActive,
                  onChanged: (v) => setState(() => _isActive = v),
                ),
              ),
              _SettingTile(
                title: 'Afficher sur ma vitrine en ligne',
                hint: 'La photo et le prix seront visibles publiquement.',
                trailing: Switch(
                  value: _isVisibleWeb,
                  onChanged: (v) => setState(() => _isVisibleWeb = v),
                ),
              ),
              // Le SECTEUR descend ici : il ne concerne que les
              // établissements qui séparent leurs chiffres (bar / cuisine), et
              // il encombrait le bloc d'identité de tous les autres.
              _SettingTile(
                title: 'Secteur',
                hint: 'Sépare les chiffres du bar et de la cuisine dans vos '
                    'rapports.',
                below: _activityField(context),
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
                  style: AppTextStyles.caption)
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final ing in _catalog)
                    // SUCCESS plein + coche : ce sont des cases cochées, pas
                    // un choix parmi d'autres. À 12 % d'accent et une bordure,
                    // coché et non coché se ressemblaient trop pour qu'on voie
                    // d'un coup d'œil ce que le plat contient.
                    _Chip(
                      label: ing.name,
                      selected:
                          _recipe.any((d) => d.ingredientId == ing.id),
                      accent: Theme.of(context).semantic.success,
                      selectedIcon: Icons.check_rounded,
                      onTap: () => _toggleIngredient(ing),
                    ),
                ],
              ),
            // BLOC À PART, sur une surface plus marquée : ces lignes ne sont
            // pas une suite de champs du formulaire, ce sont les réglages des
            // ingrédients qu'on vient de cocher juste au-dessus. Sans fond,
            // elles flottaient sous les puces sans qu'on voie ce qui les lie.
            if (_recipe.isNotEmpty) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                decoration: BoxDecoration(
                  color: sem.elevatedSurface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: sem.borderSubtle),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
              Text(
                  _hasSheetLine
                      ? 'Portions et quantités'
                      : 'Générosité des portions',
                  style: AppTextStyles.bodySmBold
                      .copyWith(color: cs.onSurface)),
              const SizedBox(height: 2),
              Text(
                  _hasSheetLine
                      ? 'Les ingrédients en fiche technique demandent la '
                          'quantité contenue dans UNE assiette. Une seule '
                          'manquante et le plat perd son coût — mieux vaut ça '
                          'qu\'un chiffre sous-évalué et crédible. Les autres '
                          'gardent leur générosité de portion.'
                      : 'Laissez « Normale » sauf si ce plat en contient '
                          'nettement plus ou moins que vos autres plats.',
                  style: AppTextStyles.caption),
              const SizedBox(height: 10),
              for (final d in _recipe)
                _PortionRow(
                  draft: d,
                  sheetMode: d.usesSheet,
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
                    // Tout décocher d'un coup — le ✕ de chaque ligne reste la
                    // voie normale pour en retirer UN.
                    Center(
                      child: TextButton.icon(
                        onPressed: _saving ? null : _clearRecipe,
                        icon: Icon(Icons.delete_sweep_outlined,
                            size: 18, color: sem.danger),
                        label: Text('Vider la composition',
                            style: AppTextStyles.label
                                .copyWith(color: sem.danger)),
                      ),
                    ),
                  ],
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
/// Puce de choix — sélectionnée en ACCENT PLEIN, sinon en simple contour.
///
/// L'état choisi se marquait par un fond d'accent à 12 % et une bordure : deux
/// nuances de la même teinte, que l'œil doit comparer pour trancher. Sur une
/// ligne de six catégories, on ne voyait plus laquelle était prise. Plein contre
/// contour se lit sans comparer.
class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// Contour discontinu : la puce ne désigne pas un choix, elle en CRÉE un.
  final bool dashed;

  /// Teinte de l'état sélectionné. Défaut : la couleur du thème. Les
  /// ingrédients d'une recette prennent `success` — ce sont des cases cochées,
  /// pas un choix parmi d'autres.
  final Color? accent;

  /// Icône posée avant le libellé, une fois la puce sélectionnée.
  final IconData? selectedIcon;

  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.dashed = false,
    this.accent,
    this.selectedIcon,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem = theme.semantic;
    final tint = accent ?? AppColors.primary;
    // Noir ou blanc selon la teinte : un vert clair et un ambre ne portent pas
    // le même texte. `estimateBrightnessForColor` évite de le deviner.
    final onTint =
        ThemeData.estimateBrightnessForColor(tint) == Brightness.dark
            ? Colors.white
            : Colors.black87;

    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (selected && selectedIcon != null) ...[
          Icon(selectedIcon, size: 15, color: onTint),
          const SizedBox(width: 6),
        ],
        Text(
          label,
          style: AppTextStyles.bodySm.copyWith(
            color: selected ? onTint : theme.colorScheme.onSurface,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ],
    );

    final box = AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
      decoration: BoxDecoration(
        color: selected ? tint : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        // Le pointillé est peint par `_DashedBorder` : laisser AUSSI une
        // bordure pleine ici dessinerait les deux l'une sur l'autre.
        border: dashed
            ? null
            : Border.all(
                color: selected ? tint : sem.borderSubtle,
                width: selected ? 1.5 : 1,
              ),
      ),
      child: content,
    );

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: dashed
          ? _DashedBorder(color: sem.borderSubtle, radius: 8, child: box)
          : box,
    );
  }
}
class _RecipeDraft {
  final String ingredientId;
  final String name;
  double portionWeight;

  /// Cet ingrédient est-il chiffré à la FICHE TECHNIQUE ? Décide, ligne par
  /// ligne, si l'on demande une quantité par portion ou une générosité.
  final bool usesSheet;

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
    this.usesSheet = false,
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
                    hintStyle: _kHintStyle,
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
  final _qtyCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  String _unit = 'kg';
  DateTime? _purchase;

  /// Unités PROPOSÉES par défaut à un restaurant — celles dans lesquelles on
  /// achète réellement au marché ou chez le grossiste.
  ///
  /// Ce n'est qu'une amorce : la liste effective est celle de la boutique
  /// (`LocalStorageService.getUnits`), à laquelle celles-ci s'ajoutent tant
  /// qu'elles n'y sont pas. Une boutique qui achète « au régime » ou « au
  /// panier » ajoute son unité depuis le menu, et elle est partagée avec le
  /// reste de l'application.
  static const _defaultUnits = [
    'kg', 'g', 'L', 'cL', 'pièce', 'boîte',
    'sachet', 'sac', 'tas', 'botte', 'casier', 'bouteille',
  ];

  /// Unités de la boutique, amorcées par [_defaultUnits]. Mutable : en ajouter
  /// une depuis le menu la rend disponible sans rouvrir la feuille.
  late final List<String> _units = _mergedUnits();

  List<String> _mergedUnits() {
    final saved = LocalStorageService.getUnits(widget.shopId);
    final out = <String>[...saved];
    for (final u in _defaultUnits) {
      if (!out.contains(u)) out.add(u);
    }
    return out;
  }

  /// Méthode de chiffrage de CET ingrédient. Répartition par défaut : c'est le
  /// comportement de tout le parc, et le seul qui ne demande rien de plus.
  String _costMethod = Ingredient.costRepartition;

  String? _err;
  bool _saving = false;

  bool get _isSheet => _costMethod == Ingredient.costSheet;

  /// La quantité achetée est OBLIGATOIRE en fiche technique.
  ///
  /// Le coût unitaire est déduit du total divisé par la quantité. Sans
  /// quantité, l'app retiendrait le montant du reçu ENTIER comme coût
  /// unitaire — puis le multiplierait par les grammes de la recette. Un sac de
  /// riz à 35 000 F donnerait 5,25 millions pour une portion de 150 g. La
  /// répartition, elle, ne divise jamais : la quantité peut y rester vide.
  bool get _qtyRequired => _isSheet;


  @override
  void dispose() {
    _nameCtrl.dispose();
    _qtyCtrl.dispose();
    _priceCtrl.dispose();
    super.dispose();
  }

  double get _qtyValue =>
      double.tryParse(_qtyCtrl.text.trim().replaceAll(',', '.')) ?? 0;

  int get _priceValue => int.tryParse(_priceCtrl.text.trim()) ?? 0;

  /// Le coût unitaire est DÉDUIT, jamais saisi : sur un reçu on lit un total
  /// et une quantité, pas un prix au kilo.
  int get _derivedUnitCost =>
      _qtyValue <= 0 ? _priceValue : (_priceValue / _qtyValue).round();

  /// L'enregistrement va-t-il produire une dépense ? Il faut les DEUX : un
  /// montant (sinon il n'y a rien à dépenser) et une quantité (sinon on
  /// déclare un achat sans marchandise, l'argent sort et le stock reste nul).
  bool get _recordsPurchase => _priceValue > 0 && _qtyValue > 0;

  Future<void> _pickPurchaseDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _purchase ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d != null && mounted) setState(() => _purchase = d);
  }

  /// Saisie d'une nouvelle unité, depuis le « + Ajouter » du menu.
  ///
  /// L'unité créée est enregistrée au niveau de la BOUTIQUE
  /// (`AppDatabase.saveUnit`, synchronisé) et non de l'ingrédient : une
  /// boutique qui achète « au régime » le fait pour plusieurs ingrédients, et
  /// devoir le ressaisir à chaque fiche serait une invitation aux fautes de
  /// frappe — « régime », « Régime », « regime » deviendraient trois unités.
  Future<String?> _addUnit(BuildContext ctx) async {
    final ctrl = TextEditingController();
    final value = await showAdaptiveFormSheet<String>(
      context: ctx,
      builder: (sheetCtx) => AdaptiveFormFrame(
        title: 'Nouvelle unité',
        subtitle: 'Elle rejoindra la liste de la boutique',
        icon: Icons.straighten_rounded,
        body: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: ctrl,
                autofocus: true,
                decoration: const InputDecoration(
                    labelText: 'Unité',
                    hintText: 'régime, panier, cuvette… *'),
                onSubmitted: (v) =>
                    Navigator.of(sheetCtx).pop(v.trim()),
              ),
              const SizedBox(height: 18),
              AppPrimaryButton(
                label: 'Ajouter',
                icon: Icons.check_rounded,
                fullWidth: true,
                onTap: () =>
                    Navigator.of(sheetCtx).pop(ctrl.text.trim()),
              ),
            ],
          ),
        ),
      ),
    );
    ctrl.dispose();
    final v = value?.trim() ?? '';
    if (v.isEmpty) return null;
    await AppDatabase.saveUnit(widget.shopId, v);
    if (mounted) setState(() => _units.add(v));
    return v;
  }

  Future<void> _submit() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _err = 'Nom requis');
      return;
    }
    // QUANTITÉ OBLIGATOIRE EN FICHE TECHNIQUE — refus net, pas une
    // confirmation : ce n'est pas une information « qu'on complétera plus
    // tard », c'est le diviseur sans lequel le coût unitaire est absurde.
    if (_qtyRequired && _qtyValue <= 0) {
      setState(() => _err =
          'La fiche technique exige la quantité achetée : le coût unitaire '
          'se déduit du montant divisé par cette quantité.');
      return;
    }
    // MONTANT ABSENT — on demande confirmation, on ne bloque pas. Interdire
    // empêcherait de composer une carte sans avoir ses factures sous la main.
    // Mais laisser passer en silence est le défaut le plus coûteux du module :
    // un ingrédient sans dépense ne pèse RIEN, donc les plats qui le
    // contiennent affichent une marge flatteuse — et un chiffre qui fait
    // plaisir ne se remet jamais en cause.
    if (!_recordsPurchase) {
      final ok = await AppConfirmDialog.show(
        context: context,
        icon: Icons.report_problem_outlined,
        iconColor: Theme.of(context).semantic.warning,
        title: 'Créer sans montant ?',
        body: const Text(
            'Sans quantité ET montant payé, aucune dépense n\'est rattachée à '
            'cet ingrédient. Ce plat sera chiffré comme s\'il était gratuit, '
            'et sa marge paraîtra meilleure qu\'elle ne l\'est.\n\n'
            'Vous pourrez régulariser plus tard depuis Finances → Réception.'),
        cancelLabel: 'Compléter',
        confirmLabel: 'Créer quand même',
        onConfirm: () {},
      );
      if (ok != true || !mounted) return;
    }

    setState(() => _saving = true);
    try {
      final ing = await IngredientService.create(
        shopId: widget.shopId,
        name: name,
        unit: _unit,
        costPerUnit: _derivedUnitCost,
        quantity: _qtyValue,
        purchaseDate: _purchase,
        costMethod: _costMethod,
      );
      // CRÉER un ingrédient avec un prix payé, C'EST UN ACHAT : la dépense
      // correspondante est écrite et rattachée. C'est elle, et elle seule, qui
      // donnera un coût aux plats qui contiennent cet ingrédient.
      if (_recordsPurchase) {
        await DailyExpenseService.record(
          shopId: widget.shopId,
          description: '$name — ${_fmtQty(_qtyValue)} $_unit',
          amount: _priceValue,
          kind: ExpenseKind.achatMarche,
          ingredientId: ing.id,
          date: _purchase,
        );
      }
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

  static String _fmtQty(double v) {
    final s = v.toStringAsFixed(3);
    return s.contains('.') ? s.replaceFirst(RegExp(r'\.?0+$'), '') : s;
  }

  String _dayLabel(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/${d.year}';

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
            // ── LA MÉTHODE D'ABORD ─────────────────────────────────────────
            // Elle décide de ce qui est demandé en dessous : en fiche
            // technique la quantité devient obligatoire. La poser en tête,
            // c'est répondre à la question avant qu'elle ne se pose.
            CostMethodPicker(
              value: _costMethod,
              onChanged: (m) => setState(() {
                _costMethod = m;
                // L'erreur affichée pouvait porter sur la quantité, qui n'est
                // plus obligatoire après un retour en répartition.
                _err = null;
              }),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _nameCtrl,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                  labelText: 'Nom', hintText: 'Poulet, huile rouge, riz… *'),
            ),
            const SizedBox(height: 12),
            AppSelectWidget(
              label: 'Unité d\'achat',
              items: _units,
              value: _unit,
              icon: Icons.straighten_rounded,
              addLabel: 'Ajouter une unité',
              onAdd: _addUnit,
              onChanged: (v) => setState(() => _unit = v),
            ),
            const SizedBox(height: 14),
            // ── L'ACHAT, saisi ici et pas ailleurs ─────────────────────────
            // On demande ce qui est écrit sur le reçu — une quantité et un
            // total — et non un coût unitaire que personne ne lit nulle part.
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _qtyCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: 'Quantité achetée',
                    // L'astérisque n'apparaît qu'en fiche technique : la
                    // répartition ne divise jamais, la quantité peut y rester
                    // vide sans rien fausser.
                    hintText: _qtyRequired ? 'ex. 25 *' : 'ex. 25',
                    suffixText: ' $_unit',
                    suffixStyle: AppTextStyles.caption,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _priceCtrl,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Montant payé (F)',
                    hintText: 'ex. 35000',
                  ),
                ),
              ),
            ]),
            if (_priceValue > 0) ...[
              const SizedBox(height: 6),
              Text(
                  _qtyValue > 0
                      ? '→ soit $_derivedUnitCost F / $_unit'
                      : '→ retenu comme coût unitaire. Sans quantité, aucune '
                          'dépense n\'est créée.',
                  style: AppTextStyles.caption),
            ],
            const SizedBox(height: 10),
            InkWell(
              onTap: _pickPurchaseDate,
              borderRadius: BorderRadius.circular(10),
              child: InputDecorator(
                decoration: InputDecoration(
                  labelText: 'Date d\'achat',
                  prefixIcon: const Icon(Icons.calendar_today, size: 18),
                  suffixIcon: _purchase == null
                      ? null
                      : IconButton(
                          tooltip: 'Effacer la date',
                          icon: const Icon(Icons.close_rounded, size: 18),
                          onPressed: () => setState(() => _purchase = null),
                        ),
                ),
                child: Text(
                    _purchase == null
                        ? 'Aujourd\'hui'
                        : _dayLabel(_purchase!),
                    style: AppTextStyles.body),
              ),
            ),
            const SizedBox(height: 10),
            // Ce que l'enregistrement va RÉELLEMENT écrire. Le dire avant est
            // la seule façon d'éviter la surprise dans les deux sens : une
            // dépense qu'on n'attendait pas, ou celle qu'on attendait en vain.
            Text(
                _recordsPurchase
                    ? 'Une dépense de $_priceValue F sera enregistrée et '
                        'rattachée à cet ingrédient : c\'est elle qui donnera '
                        'son coût aux plats qui le contiennent.'
                    : 'Sans quantité ET montant, aucun coût ne sera imputé aux '
                        'plats. Régularisable depuis Finances → Réception.',
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

/// BORDURE POINTILLÉE, peinte autour de [child].
///
/// Dit « à remplir » là où un trait plein dirait « vide ». Flutter n'a pas de
/// `BorderStyle.dashed` : il faut peindre le chemin soi-même.
///
/// [enabled] à `false` rend le widget transparent — pratique pour une vignette
/// qui perd son pointillé une fois la photo posée, sans changer d'arbre.
class _DashedBorder extends StatelessWidget {
  final Widget child;
  final Color color;
  final double radius;
  final bool enabled;

  const _DashedBorder({
    required this.child,
    required this.color,
    required this.radius,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return CustomPaint(
      foregroundPainter: _DashedPainter(color: color, radius: radius),
      child: child,
    );
  }
}

class _DashedPainter extends CustomPainter {
  final Color color;
  final double radius;

  const _DashedPainter({required this.color, required this.radius});

  /// Tiret et espace. Des tirets courts sur un petit rayon donnent un pointillé
  /// régulier ; plus longs, les angles arrondis les cassent en plein milieu.
  static const double _dash = 4;
  static const double _gap = 3.5;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(
        Offset.zero & size,
        Radius.circular(radius),
      ));

    // Le chemin est parcouru métrique par métrique : c'est la seule façon de
    // découper un tracé arrondi en segments de longueur égale.
    for (final metric in path.computeMetrics()) {
      var dist = 0.0;
      while (dist < metric.length) {
        final end = (dist + _dash).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(dist, end), paint);
        dist = end + _gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedPainter old) =>
      old.color != color || old.radius != radius;
}

/// Avertissement de plat homonyme, sous le champ Nom.
///
/// Ton WARNING et non danger : ce n'est pas une erreur, l'enregistrement reste
/// possible — deux plats de même nom sont parfois voulus. Le champ lui-même est
/// bordé de la même teinte pendant que ce message est là (cf. `borderColor`
/// d'`AppField`), pour qu'on sache lequel il concerne.
class _DupNameNotice extends StatelessWidget {
  final String name;

  const _DupNameNotice({required this.name});

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return Padding(
      padding: const EdgeInsets.only(top: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, size: 14, color: sem.warning),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Un plat nommé "$name" existe déjà à la carte.',
              style: AppTextStyles.caption.copyWith(color: sem.warningText),
            ),
          ),
        ],
      ),
    );
  }
}

/// Bandeau d'information avec une action à droite.
///
/// Pour un champ obligatoire qu'on ne PEUT pas encore remplir : il ne suffit
/// pas de proposer « + Nouvelle » au milieu de rien, il faut dire que c'est
/// attendu. Fond d'accent atténué — on informe, on n'alarme pas.
class _InfoBanner extends StatelessWidget {
  final String text;
  final String actionLabel;
  final VoidCallback onAction;

  const _InfoBanner({
    required this.text,
    required this.actionLabel,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem = theme.semantic;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: sem.brandSurface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, size: 17, color: sem.brandText),
          const SizedBox(width: 9),
          Expanded(
            child: Text(text,
                style:
                    AppTextStyles.caption.copyWith(color: sem.brandText)),
          ),
          const SizedBox(width: 6),
          TextButton(
            onPressed: onAction,
            // Hauteur explicite : le thème impose une largeur minimale infinie
            // aux boutons, qui écraserait l'Expanded voisin.
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 34),
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            child: Text(actionLabel,
                style: AppTextStyles.bodySmBold
                    .copyWith(color: AppColors.primary)),
          ),
        ],
      ),
    );
  }
}

/// Une ligne de la liste « Coût, stock et visibilité ».
///
/// Titre en gras, explication dessous, contrôle à droite — ou sous le texte
/// quand le contrôle est large (`below`). Un filet fin sépare les lignes : il
/// suffit à faire une liste, là où des cartes empilées feraient cinq blocs
/// concurrents pour des réglages qu'on ne touche presque jamais.
class _SettingTile extends StatelessWidget {
  final String title;
  final String hint;

  /// Contrôle posé à droite du texte (interrupteur, petit champ).
  final Widget? trailing;

  /// Contrôle posé SOUS le texte, sur toute la largeur — pour ce qui ne tient
  /// pas dans une marge droite, comme une rangée de puces.
  final Widget? below;

  const _SettingTile({
    required this.title,
    required this.hint,
    this.trailing,
    this.below,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem = theme.semantic;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: Border(
          // 0,5 px : un séparateur, pas un trait. À 1 px, cinq filets
          // rapprochés dessinent une grille et attirent l'œil sur des réglages
          // secondaires.
          top: BorderSide(color: sem.borderSubtle, width: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: AppTextStyles.bodySmBold
                            .copyWith(color: theme.colorScheme.onSurface)),
                    const SizedBox(height: 2),
                    Text(hint, style: AppTextStyles.caption),
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 12),
                trailing!,
              ],
            ],
          ),
          if (below != null) ...[
            const SizedBox(height: 10),
            below!,
          ],
        ],
      ),
    );
  }
}
