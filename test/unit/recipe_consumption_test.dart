// Tests du déstockage automatique des ingrédients (Lot B).
//
// Ce qui est en jeu : jusqu'ici ce décrément n'existait QUE sur le chemin de la
// caisse. Une table encaissée depuis l'addition ne retirait aucun ingrédient —
// les fiches recettes étaient chiffrées, mais l'inventaire ne bougeait jamais,
// et la réconciliation trouvait un écart à chaque service.
//
// `consumeForOrder` écrit dans Hive et n'est pas testable en unitaire ; la
// RÈGLE qu'il applique (quelle quantité, pour quel ingrédient) l'est.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/services/recipe_service.dart';
import 'package:fortress/features/caisse/domain/entities/sale_item.dart';
import 'package:fortress/features/restaurant/domain/entities/recipe_ingredient.dart';

RecipeIngredient _line(String productId, String ingredientId, double qty) =>
    RecipeIngredient(
      id: 'ri_${productId}_$ingredientId',
      shopId: 'shop_1',
      productId: productId,
      ingredientId: ingredientId,
      quantity: qty,
      unit: 'g',
      createdAt: DateTime(2026, 7, 28),
    );

SaleItem _item(String productId, {int quantity = 1}) => SaleItem(
      productId: productId,
      productName: productId,
      unitPrice: 1000,
      priceBuy: 300,
      quantity: quantity,
    );

void main() {
  group('RecipeService.plannedConsumption', () {
    test('la quantité retirée suit la quantité vendue', () {
      // 200 g de riz par plat × 3 plats = 600 g. C'est le calcul dont dépend
      // tout l'inventaire.
      final planned = RecipeService.plannedConsumption(
        {
          'plat': [_line('plat', 'riz', 200)],
        },
        [_item('plat', quantity: 3)],
      );
      expect(planned['riz'], 600);
    });

    test('un ingrédient partagé est retiré en ENTIER pour chaque plat', () {
      // Le prorata des ingrédients partagés ne concerne QUE le coût. Diviser
      // aussi le stock laisserait de l'huile fantôme dans l'inventaire à
      // chaque service.
      final planned = RecipeService.plannedConsumption(
        {
          'poulet': [_line('poulet', 'huile', 10)],
          'poisson': [_line('poisson', 'huile', 10)],
        },
        [_item('poulet'), _item('poisson')],
      );
      expect(planned['huile'], 20);
    });

    test('les lignes du même ingrédient sont agrégées en un seul retrait', () {
      // Deux plats qui partagent l'huile ne doivent produire qu'une écriture :
      // c'est ce qui évite deux upserts concurrents sur le même ingrédient.
      final planned = RecipeService.plannedConsumption(
        {
          'poulet': [_line('poulet', 'huile', 10), _line('poulet', 'sel', 2)],
          'poisson': [_line('poisson', 'huile', 5)],
        },
        [_item('poulet', quantity: 2), _item('poisson', quantity: 4)],
      );
      expect(planned.keys.length, 2);
      expect(planned['huile'], 40); // (10 × 2) + (5 × 4)
      expect(planned['sel'], 4);
    });

    test('un plat sans fiche recette ne consomme rien', () {
      // Cas très courant : une bière n'a pas de recette. Elle ne doit surtout
      // pas faire échouer le décrément des plats vendus avec elle.
      final planned = RecipeService.plannedConsumption(
        {
          'plat': [_line('plat', 'riz', 100)],
        },
        [_item('plat'), _item('biere', quantity: 3)],
      );
      expect(planned['riz'], 100);
      expect(planned.containsKey('biere'), isFalse);
    });

    test('un panier vide ne consomme rien', () {
      expect(RecipeService.plannedConsumption({}, const []), isEmpty);
    });

    test('les fractions d\'unité sont conservées', () {
      // 0,25 L d'huile × 3 = 0,75 L. Arrondir ici ferait dériver l'inventaire
      // d'un quart de litre par service.
      final planned = RecipeService.plannedConsumption(
        {
          'friture': [_line('friture', 'huile', 0.25)],
        },
        [_item('friture', quantity: 3)],
      );
      expect(planned['huile'], closeTo(0.75, 1e-9));
    });
  });
}
