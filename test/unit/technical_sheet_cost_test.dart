// Tests de la FICHE TECHNIQUE — la seconde méthode de coût matières.
//
// LA MÉTHODE : coût d'une portion = Σ (quantité × coût unitaire de
// l'ingrédient). Elle est l'exact opposé de la répartition au prorata : elle
// ignore complètement ce qui a été acheté sur la période et ne regarde que la
// recette. Stable d'un mois à l'autre, mais elle exige une quantité par ligne.
//
// LA RÈGLE QUI COMPTE : une fiche trouée ne rend RIEN. Un coût partiel serait
// sous-évalué et parfaitement crédible — c'est-à-dire indétectable. Mieux vaut
// dire « je ne sais pas » que mentir sur une marge.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/services/dish_cost_service.dart';
import 'package:fortress/features/restaurant/domain/entities/ingredient.dart';
import 'package:fortress/features/restaurant/domain/entities/recipe_ingredient.dart';

RecipeIngredient _line({
  double quantity = 0,
  String unit = 'g',
  bool confirmed = false,
}) =>
    RecipeIngredient(
      id: 'ri_1',
      shopId: 'shop_1',
      productId: 'p_1',
      ingredientId: 'ig_1',
      createdAt: DateTime(2026, 1, 1),
      quantity: quantity,
      unit: unit,
      quantityConfirmed: confirmed,
    );

void main() {
  group('TechnicalSheetService.computeCost', () {
    test('l\'exemple de référence tombe juste', () {
      // 150 g de poulet à 4 F/g + 200 g de riz à 1 F/g = 600 + 200 = 800 F.
      final cost = TechnicalSheetService.computeCost([
        (quantity: 150, costPerUnit: 4),
        (quantity: 200, costPerUnit: 1),
      ]);
      expect(cost, 800);
    });

    test('une fiche vide ne rend rien (et non zéro)', () {
      // Zéro voudrait dire « ce plat ne coûte rien », ce qui est faux.
      expect(TechnicalSheetService.computeCost(const []), isNull);
    });

    test('une quantité manquante annule TOUTE la fiche', () {
      final cost = TechnicalSheetService.computeCost([
        (quantity: 150, costPerUnit: 4),
        (quantity: 0, costPerUnit: 1), // non renseignée
      ]);
      expect(cost, isNull,
          reason: 'un coût partiel serait crédible, donc indétectable');
    });

    test('un ingrédient sans coût unitaire annule TOUTE la fiche', () {
      final cost = TechnicalSheetService.computeCost([
        (quantity: 150, costPerUnit: 4),
        (quantity: 200, costPerUnit: 0), // achat jamais renseigné
      ]);
      expect(cost, isNull);
    });

    test('une quantité non finie ne passe pas', () {
      expect(
          TechnicalSheetService.computeCost([
            (quantity: double.infinity, costPerUnit: 4),
          ]),
          isNull);
      expect(
          TechnicalSheetService.computeCost([
            (quantity: double.nan, costPerUnit: 4),
          ]),
          isNull);
    });

    test('les décimales ne sont pas arrondies en cours de route', () {
      // 2,5 kg à 1 400 F/kg = 3 500 F. Un arrondi par ligne donnerait 3 500
      // aussi ici, mais l'invariant doit tenir sur les quantités fines.
      expect(
          TechnicalSheetService.computeCost([
            (quantity: 2.5, costPerUnit: 1400),
            (quantity: 0.125, costPerUnit: 4000),
          ]),
          3500 + 500);
    });
  });

  group('RecipeIngredient.isPriceable — les trois conditions', () {
    test('quantité confirmée, positive et avec unité → chiffrable', () {
      expect(_line(quantity: 150, confirmed: true).isPriceable, isTrue);
    });

    test('quantité héritée NON confirmée → pas chiffrable', () {
      // C'est le cœur de la migration v2 : les quantités saisies avant
      // l'abandon de la méthode n'ont jamais été relues. Les chiffrer
      // produirait des coûts faux et plausibles.
      expect(_line(quantity: 150).isPriceable, isFalse);
    });

    test('quantité nulle → pas chiffrable', () {
      expect(_line(confirmed: true).isPriceable, isFalse);
    });

    test('unité absente → pas chiffrable', () {
      expect(
          _line(quantity: 150, unit: '', confirmed: true).isPriceable, isFalse);
    });
  });

  group('Migration v2 — les quantités héritées', () {
    test('une ligne antérieure est relue comme NON confirmée', () {
      // Carte d'une ligne écrite avant la v2 : pas de `quantity_confirmed`.
      final legacy = RecipeIngredient.fromMap({
        'id': 'ri_old',
        'shop_id': 'shop_1',
        'product_id': 'p_1',
        'ingredient_id': 'ig_1',
        'portion_weight': 1.0,
        'quantity': 125.0,
        'unit': 'g',
        'created_at': '2026-01-01T00:00:00.000Z',
      });
      expect(legacy.quantity, 125.0, reason: 'la saisie est conservée');
      expect(legacy.quantityConfirmed, isFalse);
      expect(legacy.isPriceable, isFalse);
    });

    test('une ligne écrite aujourd\'hui garde sa confirmation', () {
      final fresh = RecipeIngredient.fromMap(
          _line(quantity: 125, confirmed: true).toMap());
      expect(fresh.quantityConfirmed, isTrue);
      expect(fresh.isPriceable, isTrue);
    });

    test('la migration est idempotente', () {
      final once = RecipeIngredient.fromMap({
        'id': 'ri_old',
        'shop_id': 'shop_1',
        'product_id': 'p_1',
        'ingredient_id': 'ig_1',
        'quantity': 125.0,
        'unit': 'g',
        'created_at': '2026-01-01T00:00:00.000Z',
      });
      final twice = RecipeIngredient.fromMap(once.toMap());
      expect(twice.quantityConfirmed, once.quantityConfirmed);
      expect(twice.quantity, once.quantity);
    });
  });

  group('Ingredient.costMethod — le choix vit sur l\'ingrédient', () {
    Ingredient ing(String method) => Ingredient(
          id: 'ig_1',
          shopId: 'shop_1',
          name: 'Riz',
          createdAt: DateTime(2026, 1, 1),
          costMethod: method,
        );

    test('la répartition reste le défaut', () {
      expect(
          Ingredient(
                  id: 'ig_1',
                  shopId: 'shop_1',
                  name: 'Piment',
                  createdAt: DateTime(2026, 1, 1))
              .usesTechnicalSheet,
          isFalse);
    });

    test('seule la valeur exacte active la fiche', () {
      expect(ing(Ingredient.costSheet).usesTechnicalSheet, isTrue);
      expect(ing(Ingredient.costRepartition).usesTechnicalSheet, isFalse);
    });

    test('une valeur abîmée retombe sur la répartition, pas sur une erreur',
        () {
      // Une donnée corrompue ne doit pas rendre un plat non chiffrable : elle
      // doit le ramener au comportement par défaut.
      final parsed = Ingredient.fromMap({
        'id': 'ig_1',
        'shop_id': 'shop_1',
        'name': 'Riz',
        'cost_method': 'n_importe_quoi',
        'created_at': '2026-01-01T00:00:00.000Z',
      });
      expect(parsed.usesTechnicalSheet, isFalse);
      expect(parsed.costMethod, Ingredient.costRepartition);
    });

    test('migration v2 — un ingrédient antérieur est en répartition', () {
      final legacy = Ingredient.fromMap({
        'id': 'ig_old',
        'shop_id': 'shop_1',
        'name': 'Huile',
        'created_at': '2026-01-01T00:00:00.000Z',
      });
      expect(legacy.costMethod, Ingredient.costRepartition);
    });

    test('la méthode fait l\'aller-retour par la carte', () {
      for (final m in [Ingredient.costRepartition, Ingredient.costSheet]) {
        expect(Ingredient.fromMap(ing(m).toMap()).costMethod, m);
      }
    });
  });
}
