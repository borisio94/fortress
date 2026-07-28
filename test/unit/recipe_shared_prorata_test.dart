// Tests unitaires du prorata de coût des ingrédients PARTAGÉS
// (module finances — PR-A, correctif « plats supprimés »).
//
// Le coût d'un ingrédient partagé est divisé par le nombre de plats qui
// l'utilisent. Compter un plat SUPPRIMÉ dans ce diviseur sous-estime le coût
// matières de tous les autres plats — donc surestime leur marge, en silence :
// un ingrédient à 900 F partagé entre 2 plats vivants et 1 plat supprimé
// facturait 300 F au lieu de 450 F.
//
// `dishCountForIngredient` lit Hive et n'est pas testable en unitaire ; la
// règle qu'il applique, elle, est isolée dans `isLiveProductMap`.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/services/recipe_service.dart';

void main() {
  group('Plat vivant ou non', () {
    test('un plat sans deleted_at compte', () {
      expect(
          RecipeService.isLiveProductMap({'id': 'prod_1', 'name': 'Ndolé'}),
          isTrue);
    });

    test('un deleted_at null compte (colonne présente, plat vivant)', () {
      // Cas le plus courant : la colonne existe et vaut null pour tout le
      // catalogue en service.
      expect(
          RecipeService.isLiveProductMap(
              {'id': 'prod_1', 'deleted_at': null}),
          isTrue);
    });

    test('un deleted_at vide compte (chaîne vide ≠ suppression)', () {
      // Vu en base : certains chemins écrivent '' plutôt que null. Traiter
      // cette ligne comme supprimée retirerait un plat bien vivant du
      // diviseur et surfacturerait les autres.
      expect(
          RecipeService.isLiveProductMap({'id': 'prod_1', 'deleted_at': ''}),
          isTrue);
    });

    test('un plat soft-deleted ne compte pas', () {
      expect(
          RecipeService.isLiveProductMap(
              {'id': 'prod_1', 'deleted_at': '2026-07-20T10:00:00Z'}),
          isFalse);
    });

    test('un plat introuvable ne compte pas', () {
      // Ligne de recette orpheline : le produit a été purgé ou n'a jamais été
      // synchronisé sur cet appareil.
      expect(RecipeService.isLiveProductMap(null), isFalse);
    });
  });

  group('Effet sur le prorata', () {
    // Reproduit `lineCost` : (quantité × coût unitaire) ÷ nb_plats, le
    // diviseur venant de `dishCountForIngredient`.
    double lineCost(double qty, int costPerUnit, int dishCount,
        {bool shared = true}) {
      final raw = qty * costPerUnit;
      if (!shared) return raw;
      return dishCount <= 1 ? raw : raw / dishCount;
    }

    test('le plat supprimé ne dilue plus le coût', () {
      // 1 unité à 900 F partagée entre 3 lignes dont 1 plat supprimé.
      const rawMaps = [
        {'id': 'prod_1'},
        {'id': 'prod_2'},
        {'id': 'prod_3', 'deleted_at': '2026-07-20T10:00:00Z'},
      ];
      final live =
          rawMaps.where(RecipeService.isLiveProductMap).length;
      expect(live, 2);
      // Avant le correctif : 900 / 3 = 300 F. Après : 900 / 2 = 450 F.
      expect(lineCost(1, 900, live), 450);
    });

    test('un seul plat vivant porte 100 % du coût', () {
      // Même marqué « shared » en base, un ingrédient qui ne sert plus qu'à un
      // plat ne se divise pas — le garde-fou `n <= 1` évite d'attendre que le
      // type repasse à « specialized ».
      expect(lineCost(1, 900, 1), 900);
    });

    test('aucun plat vivant : pas de division par zéro', () {
      expect(lineCost(1, 900, 0), 900);
    });

    test('un ingrédient spécialisé n\'est jamais divisé', () {
      expect(lineCost(2, 500, 3, shared: false), 1000);
    });
  });
}
