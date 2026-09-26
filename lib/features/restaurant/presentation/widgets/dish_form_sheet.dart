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
import 'ingredient_quick_sheet.dart';
import '../../../../shared/widgets/app_confirm_dialog.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/product_image_card.dart';
import '../../domain/category_labels.dart';
import '../../domain/entities/ingredient.dart';
import '../../domain/entities/recipe_ingredient.dart';
import '../../domain/entities/restaurant_activity.dart';
import 'resto_empty_state.dart';

part 'dish_form_sheet.recipe.dart';
part 'dish_form_sheet.widgets.dart';

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

/// SEUIL DE CONTENU (document de design § 8) : à partir de 560 px de
/// CONTENEUR, le nom et le prix se posent À CÔTÉ de la vignette — une colonne
/// d'au moins 456 px (560 − 88 de photo − 16 d'écart) ; empilés en dessous.
const double kDishIdentitySideBySideMin = 560;

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
  /// Liste vide (aucune activité créée) → le champ Secteur dit où les créer
  /// (`_activityField`) ; non vide → il les propose, et le titre du bloc
  /// replié signale un plat sans secteur.
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

  /// Une puce par catégorie, à la casse et aux accents près (`categoryLabels`).
  ///
  /// Les catégories DÉCLARÉES et celles que PORTENT les plats sont comptées
  /// ensemble : le libellé retenu est ainsi le même que l'onglet du Menu, qui
  /// choisit l'orthographe la plus portée par les plats.
  List<String> get _categories => categoryLabels([
        for (final p in LocalStorageService.getProductsForShop(widget.shopId))
          p.categoryId,
        ...LocalStorageService.getCategories(widget.shopId),
      ]).values.toList()
        ..sort();

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
    // Le châssis CANONIQUE d'une saisie (`AdaptiveFormFrame`), pas un
    // `AlertDialog` : page pleine sur téléphone, où le clavier ne recouvre
    // plus le champ ; feuille sur ordinateur. Fermer la feuille vaut
    // « Annuler », comme l'ancien bouton du même nom.
    final name = await showAdaptiveFormSheet<String>(
      context: context,
      builder: (sheetCtx) => AdaptiveFormFrame(
        title: 'Nouvelle catégorie',
        icon: Icons.category_outlined,
        body: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppField(
                controller: ctrl,
                hint: 'Entrées, Plats, Boissons…',
                autofocus: true,
              ),
              const SizedBox(height: 18),
              AppPrimaryButton(
                label: 'Ajouter',
                icon: Icons.check_rounded,
                fullWidth: true,
                onTap: () => Navigator.of(sheetCtx).pop(ctrl.text.trim()),
              ),
            ],
          ),
        ),
      ),
    );
    ctrl.dispose();
    if (name == null || name.isEmpty || !mounted) return;
    // « plats » alors que « Plats » existe : on REPREND l'existante au lieu
    // d'en créer une seconde, qui ferait un deuxième onglet au Menu. Même
    // règle que les noms de plats (`nameKey`).
    for (final c in _categories) {
      if (sameCategory(c, name)) {
        setState(() => _category = c);
        return;
      }
    }
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
      builder: (_) => IngredientQuickSheet(shopId: widget.shopId),
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
                // À la casse près : un plat rangé sous « plats » allume la
                // puce « Plats ». Sans y toucher, il garde son texte.
                selected: sameCategory(_category, c),
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
      return const RestoEmptyNote(
          'Aucun secteur défini. Ils se créent dans Finances → Activités, pour '
          'séparer les chiffres du bar et de la cuisine.');
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
            // Sous [kDishIdentitySideBySideMin], une colonne de champs à côté
            // d'une vignette redevient trop étroite pour un prix et un nom, et
            // l'on empile.
            LayoutBuilder(builder: (_, c) {
              final side = c.maxWidth >= kDishIdentitySideBySideMin;
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
                    // Le secteur y manquait : on créait un plat sans jamais
                    // croiser le champ.
                    Flexible(
                      child: Text('Coût, secteur, stock et visibilité',
                          style: AppTextStyles.bodySmBold
                              .copyWith(color: cs.onSurface)),
                    ),
                    // CE QUI RESTE À REMPLIR, vu bloc fermé. Seulement si la
                    // boutique a des secteurs — sans eux il n'y a rien à
                    // choisir, et la plupart des restaurants n'en ont pas — et
                    // seulement replié : ouvert, le champ se voit lui-même.
                    // Ton neutre : « Aucun » reste un choix valide, le plat
                    // ira simplement sous « Sans secteur ».
                    if (!_advanced &&
                        _activities.isNotEmpty &&
                        _activityId == null) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: sem.info.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text('Secteur à choisir',
                            maxLines: 1,
                            style: AppTextStyles.microBold
                                .copyWith(color: AppColors.textSecondary)),
                      ),
                    ],
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
                        AppTextStyles.caption.copyWith(color: sem.warningText)),
              ),
            if (_catalog.isEmpty)
              const RestoEmptyNote(
                  'Aucun ingrédient dans votre catalogue. Créez-en un pour '
                  'commencer à suivre le coût de ce plat.')
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
                      ? 'Les ingrédients en « Quantité connue » demandent la '
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
                                .copyWith(color: sem.dangerText)),
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
                      AppTextStyles.caption.copyWith(color: sem.dangerText)),
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
                            AppTextStyles.label.copyWith(color: sem.dangerText)),
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
