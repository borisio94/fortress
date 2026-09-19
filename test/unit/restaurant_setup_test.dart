// Tests de la règle de mise en route d'un restaurant.
//
// CE QUI EST EN JEU : cette règle décide si l'application entière est ouverte
// ou repliée sur un écran de configuration. Une erreur dans un sens enferme un
// restaurant en service dans un stepper dont il ne peut pas sortir ; dans
// l'autre, elle laisse un restaurant vide vendre des plats dont le coût est
// inconnu.
//
// L'étape est TOUJOURS recalculée depuis les données — aucun drapeau n'est
// stocké. Un drapeau se serait désynchronisé au premier chemin oublié : un
// restaurant qui supprime sa dernière table serait resté « configuré ».

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/services/restaurant_setup_service.dart';

RestaurantSetupStep step({
  bool hasTable = true,
  bool hasComposedDish = true,
  bool hasIngredientCost = true,
}) =>
    RestaurantSetupService.decide(
      hasTable: hasTable,
      hasComposedDish: hasComposedDish,
      hasIngredientCost: hasIngredientCost,
    );

void main() {
  group('Ordre des étapes', () {
    test('sans table, la première étape s\'impose', () {
      expect(
          step(
              hasTable: false,
              hasComposedDish: false,
              hasIngredientCost: false),
          RestaurantSetupStep.needsTable);
    });

    test('la table passe avant tout le reste, même si le reste est fait', () {
      // L'ordre n'est pas négociable : sans table, aucun service ne peut
      // s'ouvrir, et une carte seule ne sert à rien.
      expect(step(hasTable: false), RestaurantSetupStep.needsTable);
    });

    test('avec une table mais aucun plat composé, on passe à l\'étape 2', () {
      expect(step(hasComposedDish: false, hasIngredientCost: false),
          RestaurantSetupStep.needsMenuItem);
    });

    test('le plat passe avant les achats', () {
      // Renseigner des achats sans plat composé n'imputerait rien à personne.
      expect(step(hasComposedDish: false), RestaurantSetupStep.needsMenuItem);
    });

    test('plat composé mais aucun achat : étape 3', () {
      expect(step(hasIngredientCost: false),
          RestaurantSetupStep.needsIngredientCost);
    });

    test('les trois faits : configuration terminée', () {
      expect(step(), RestaurantSetupStep.complete);
      expect(step().isComplete, isTrue);
    });
  });

  group('Retour en arrière', () {
    test('supprimer sa dernière table ramène à l\'étape 1', () {
      // C'est précisément ce qu'un drapeau stocké aurait raté : il serait
      // resté à « complete » avec une salle vide.
      expect(step(hasTable: false).isComplete, isFalse);
    });

    test('supprimer son dernier plat composé ramène à l\'étape 2', () {
      expect(step(hasComposedDish: false), RestaurantSetupStep.needsMenuItem);
    });

    test('supprimer la dernière dépense ramène à l\'étape 3', () {
      // Un ingrédient qui perd son achat rend gratuits les plats qui le
      // portent : la marge redevient fausse, la configuration n'est plus
      // valide.
      expect(step(hasIngredientCost: false),
          RestaurantSetupStep.needsIngredientCost);
    });
  });

  group('Rang affiché dans le stepper', () {
    test('les trois rangs se suivent', () {
      expect(RestaurantSetupStep.needsTable.index1, 1);
      expect(RestaurantSetupStep.needsMenuItem.index1, 2);
      expect(RestaurantSetupStep.needsIngredientCost.index1, 3);
    });

    test('le total annoncé correspond au nombre d\'étapes', () {
      expect(RestaurantSetupStep.totalSteps, 3);
      // Une seule valeur de l'enum n'est pas une étape : « complete ».
      expect(RestaurantSetupStep.values.length,
          RestaurantSetupStep.totalSteps + 1);
    });
  });

  group('Boutique sans identifiant', () {
    test('ne bloque jamais', () {
      // Au tout premier rendu, ou sur un chemin sans shopId, on ne doit pas
      // enfermer l'utilisateur dans une configuration qui ne le concerne pas.
      expect(RestaurantSetupService.stepFor('').isComplete, isTrue);
    });
  });
}
