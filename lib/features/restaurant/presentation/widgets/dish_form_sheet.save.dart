part of 'dish_form_sheet.dart';

// L'ENREGISTREMENT de la fiche plat, sans widget : construire le plat à
// partir de la saisie, mettre sa photo en file, écrire sa recette, et régler
// le sort des achats faits pour un plat abandonné.
//
// Ni `setState`, ni `context` : la fiche garde la main sur ce qu'elle affiche
// (erreurs, avertissements, fermeture) et appelle ceci pour le reste.
// Extrait de `_DishFormSheetState` le 26/09/2026 (lot « classes géantes »),
// sous le banc `test/widget/dish_form_sheet_test.dart`.

/// Un montant saisi (« 3500 », « 3,5 »), `null` s'il ne se lit pas.
double? _parseAmount(String raw) =>
    double.tryParse(raw.trim().replaceAll(',', '.'));

/// Le plat tel que la fiche l'enregistre.
///
/// [existing] : le plat en édition, `null` à la création. [ts] fixe
/// l'identifiant de la variante créée — le même instant que celui du nom de
/// la photo.
Product _buildDishProduct({
  required Product? existing,
  required String productId,
  required String shopId,
  required String name,
  required String? category,
  required String description,
  required double price,
  required double cost,
  required bool isActive,
  required bool isVisibleWeb,
  required bool trackStock,
  required String? activityId,
  required int rating,
  required int ts,
}) {
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

  return Product(
    id: productId,
    storeId: shopId,
    name: name,
    categoryId: category,
    description: description.trim().isEmpty ? null : description.trim(),
    priceBuy: cost,
    // Un seul prix : la distinction comptoir / web est une notion
    // e-commerce, sans objet sur une carte de restaurant.
    priceSellPos: price,
    priceSellWeb: price,
    isActive: isActive,
    isVisibleWeb: isVisibleWeb,
    trackStock: trackStock,
    activityId: activityId,
    rating: rating,
    imageUrl: existing?.imageUrl,
    variants: [variant],
    createdAt: existing?.createdAt ?? DateTime.now(),
  );
}

/// Les écritures de la fiche plat, pour une boutique.
class _DishStore {
  final String shopId;

  const _DishStore(this.shopId);

  /// Met la photo du plat en file d'envoi.
  ///
  /// La photo est un ORNEMENT : `enqueue` écrit dans Hive sans filet
  /// (`box.add` nu, avec les octets de l'image dedans). Une box pleine ou
  /// fermée faisait perdre la recette d'un plat, pour une vignette — d'où
  /// l'erreur avalée ici.
  Future<void> enqueuePhoto({
    required String productId,
    required Uint8List bytes,
    required int ts,
  }) async {
    try {
      await PendingImageUploadService.enqueue(
        shopId: shopId,
        productId: productId,
        variantIdx: 0,
        bytes: bytes,
        name: 'shops/$shopId/products/${ts}_0',
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

  /// Écrit la recette, avec UN réessai.
  ///
  /// Renvoie `false` si les deux tentatives échouent. [syncRecipe] est
  /// idempotent — `addLink` met à jour la ligne existante au lieu d'en créer une
  /// seconde — donc rejouer ne peut pas doubler une composition.
  ///
  /// Un seul réessai, pas une boucle : ce qui peut échouer ici est une écriture
  /// Hive locale. Si elle échoue deux fois de suite, insister ne changera rien
  /// et fera attendre quelqu'un en plein service.
  Future<bool> trySyncRecipe(
      String productId, List<_RecipeDraft> recipe) async {
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        await syncRecipe(productId, recipe);
        return true;
      } catch (e) {
        debugPrint('[DishForm] recette, tentative $attempt : $e');
      }
    }
    return false;
  }

  /// Aligne les liens persistés sur le brouillon [recipe] : (ré)écrit les
  /// présents, supprime ceux décochés.
  Future<void> syncRecipe(String productId, List<_RecipeDraft> recipe) async {
    final currentIds = recipe.map((d) => d.ingredientId).toSet();
    for (final line in RecipeService.forProduct(shopId, productId)) {
      if (!currentIds.contains(line.ingredientId)) {
        await RecipeService.removeLine(line);
      }
    }
    for (final d in recipe) {
      await RecipeService.addLink(
        shopId: shopId,
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

  /// Total des achats déjà rattachés à cet ingrédient (FCFA).
  int purchasesFor(String ingredientId) {
    var total = 0;
    for (final e in DailyExpenseService.forShop(shopId)) {
      if (e.ingredientId == ingredientId) total += e.amount;
    }
    return total;
  }

  /// Supprime les achats ET les ingrédients qui les portent.
  ///
  /// Les deux ensemble : garder un ingrédient sans achat le ferait remonter en
  /// orange dans la liste des ingrédients « sans dépense », pour une saisie que
  /// l'utilisateur vient justement d'annuler.
  Future<void> discardPurchases(List<Ingredient> ingredients) async {
    for (final ing in ingredients) {
      for (final e in DailyExpenseService.forShop(shopId)) {
        if (e.ingredientId == ing.id) {
          await DailyExpenseService.delete(e.id, shopId);
        }
      }
      await IngredientService.delete(ing.id, shopId);
    }
  }
}
