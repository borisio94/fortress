// Tests de la répartition du coût des ingrédients au prorata des ventes.
//
// LA MÉTHODE : on ne demande AUCUNE quantité par plat. On sait seulement quels
// plats contiennent quel ingrédient. Le coût réellement dépensé pour cet
// ingrédient est réparti entre eux au prorata de ce qui s'est vendu :
//
//   part d'un plat = dépense × poids_portion ÷ Σ(quantités vendues × poids)
//
// L'INVARIANT qui garantit que le calcul est honnête : la somme de ce qui est
// imputé aux assiettes vendues, plus ce qui n'a pu l'être, égale exactement ce
// qui a été dépensé. La répartition ne crée ni ne perd d'argent.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/services/ingredient_allocation_service.dart';
import 'package:fortress/features/restaurant/domain/entities/recipe_ingredient.dart';

AllocationResult _allocate({
  required Map<String, int> spend,
  required Map<String, List<DishLink>> links,
  required Map<String, double> sold,
}) =>
    IngredientAllocationService.allocate(
      spendByIngredient: spend,
      linksByIngredient: links,
      soldByProduct: sold,
    );

void main() {
  group('Répartition au prorata des ventes', () {
    test('l\'exemple de référence tombe juste', () {
      // 140 000 F de poulet, 120 Ndolé + 80 Riz sauté vendus → 200 parts,
      // donc 700 F de poulet par plat.
      final r = _allocate(
        spend: {'poulet': 140000},
        links: {
          'poulet': [
            (productId: 'ndole', weight: 1),
            (productId: 'riz', weight: 1),
          ],
        },
        sold: {'ndole': 120, 'riz': 80},
      );
      expect(r.forProduct('ndole'), closeTo(700, 0.001));
      expect(r.forProduct('riz'), closeTo(700, 0.001));
      expect(r.unallocated, 0);
    });

    test('un seul plat porte tout le coût de son ingrédient', () {
      final r = _allocate(
        spend: {'capitaine': 60000},
        links: {
          'capitaine': [(productId: 'braise', weight: 1)],
        },
        sold: {'braise': 50},
      );
      expect(r.forProduct('braise'), closeTo(1200, 0.001));
    });

    test('les coûts de plusieurs ingrédients s\'additionnent sur le plat', () {
      final r = _allocate(
        spend: {'poulet': 100000, 'huile': 20000},
        links: {
          'poulet': [(productId: 'ndole', weight: 1)],
          'huile': [
            (productId: 'ndole', weight: 1),
            (productId: 'frites', weight: 1),
          ],
        },
        sold: {'ndole': 100, 'frites': 100},
      );
      // 1 000 F de poulet + 100 F d'huile.
      expect(r.forProduct('ndole'), closeTo(1100, 0.001));
      expect(r.forProduct('frites'), closeTo(100, 0.001));
    });
  });

  group('Générosité des portions', () {
    test('une grande part coûte plus qu\'une petite', () {
      // 120 000 F, 100 plats à 1,5 et 100 plats à 0,5 → 200 parts pondérées,
      // soit 600 F la part : 900 F pour le généreux, 300 F pour l'autre.
      final r = _allocate(
        spend: {'viande': 120000},
        links: {
          'viande': [
            (productId: 'grand', weight: RecipeIngredient.largePortion),
            (productId: 'petit', weight: RecipeIngredient.smallPortion),
          ],
        },
        sold: {'grand': 100, 'petit': 100},
      );
      expect(r.forProduct('grand'), closeTo(900, 0.001));
      expect(r.forProduct('petit'), closeTo(300, 0.001));
    });

    test('un poids nul exclut le plat de la répartition', () {
      final r = _allocate(
        spend: {'viande': 100000},
        links: {
          'viande': [
            (productId: 'plat', weight: 1),
            (productId: 'exclu', weight: 0),
          ],
        },
        sold: {'plat': 100, 'exclu': 100},
      );
      expect(r.forProduct('plat'), closeTo(1000, 0.001));
      expect(r.forProduct('exclu'), 0);
    });
  });

  group('L\'argent ne se perd ni ne se crée', () {
    test('réparti + non réparti = dépensé', () {
      final r = _allocate(
        spend: {'poulet': 140000, 'riz': 60000, 'jamais_vendu': 30000},
        links: {
          'poulet': [
            (productId: 'ndole', weight: 1.5),
            (productId: 'grille', weight: 1),
          ],
          'riz': [(productId: 'grille', weight: 1)],
          'jamais_vendu': [(productId: 'plat_retire', weight: 1)],
        },
        sold: {'ndole': 37, 'grille': 63},
      );
      expect(r.allocated + r.unallocated, closeTo(230000, 0.01));
    });

    test('un ingrédient dont aucun plat ne s\'est vendu n\'est pas réparti', () {
      // Stock constitué d'avance, ou plat retiré de la carte. Ces francs
      // restent dans le food cost global, ils ne sont imputables à personne.
      final r = _allocate(
        spend: {'poulet': 140000},
        links: {
          'poulet': [(productId: 'ndole', weight: 1)],
        },
        sold: const {},
      );
      expect(r.unallocated, 140000);
      expect(r.forProduct('ndole'), 0);
      expect(r.allocated, 0);
    });

    test('un ingrédient sans plat coché n\'est pas réparti', () {
      final r = _allocate(
        spend: {'orphelin': 50000},
        links: const {},
        sold: {'ndole': 100},
      );
      expect(r.unallocated, 50000);
      expect(r.forProduct('ndole'), 0);
    });
  });

  group('Cas limites', () {
    test('aucune dépense : aucun coût, aucune division par zéro', () {
      final r = _allocate(
        spend: const {},
        links: {
          'poulet': [(productId: 'ndole', weight: 1)],
        },
        sold: {'ndole': 100},
      );
      expect(r.isEmpty, isTrue);
      expect(r.forProduct('ndole'), 0);
      expect(r.unallocated, 0);
    });

    test('une dépense nulle ou négative est ignorée', () {
      final r = _allocate(
        spend: {'a': 0, 'b': -500},
        links: {
          'a': [(productId: 'ndole', weight: 1)],
          'b': [(productId: 'ndole', weight: 1)],
        },
        sold: {'ndole': 10},
      );
      expect(r.forProduct('ndole'), 0);
      expect(r.unallocated, 0);
    });

    test('un plat lié mais non vendu ne dilue pas les autres', () {
      // Le dénominateur ne compte que ce qui s'est VENDU : un plat à la carte
      // mais jamais commandé ne doit pas absorber une part du poulet, sinon
      // les plats réellement vendus seraient sous-facturés.
      final r = _allocate(
        spend: {'poulet': 100000},
        links: {
          'poulet': [
            (productId: 'vendu', weight: 1),
            (productId: 'jamais', weight: 1),
          ],
        },
        sold: {'vendu': 100},
      );
      expect(r.forProduct('vendu'), closeTo(1000, 0.001));
      expect(r.forProduct('jamais'), 0);
      expect(r.unallocated, 0);
    });
  });

  group('Poids de portion — assainissement', () {
    RecipeIngredient link(double w) => RecipeIngredient(
          id: 'ri_1',
          shopId: 'shop_1',
          productId: 'p1',
          ingredientId: 'i1',
          portionWeight: w,
          createdAt: DateTime(2026, 7, 1),
        );

    test('le défaut est la portion normale', () {
      expect(RecipeIngredient.normalPortion, 1.0);
      final l = RecipeIngredient(
        id: 'ri_1',
        shopId: 'shop_1',
        productId: 'p1',
        ingredientId: 'i1',
        createdAt: DateTime(2026, 7, 1),
      );
      expect(l.effectiveWeight, 1.0);
    });

    test('un poids négatif ou non fini est neutralisé', () {
      expect(link(-2).effectiveWeight, 0);
      expect(link(double.nan).effectiveWeight, 0);
      expect(link(double.infinity).effectiveWeight, 0);
    });

    test('un lien antérieur à la méthode devient une portion normale', () {
      // Les fiches déjà saisies n'ont pas de `portion_weight` : elles se
      // répartissent à parts égales plutôt que de disparaître du calcul.
      final legacy = RecipeIngredient.fromMap({
        'id': 'ri_9',
        'shop_id': 'shop_1',
        'product_id': 'p1',
        'ingredient_id': 'i1',
        'quantity': 0.125,
        'unit': 'kg',
      });
      expect(legacy.portionWeight, RecipeIngredient.normalPortion);
      // La quantité est conservée mais n'est plus lue par le calcul.
      expect(legacy.quantity, 0.125);
    });

    test('aller-retour toMap/fromMap sans perte', () {
      final back = RecipeIngredient.fromMap(link(1.5).toMap());
      expect(back.portionWeight, 1.5);
      expect(back.productId, 'p1');
      expect(back.ingredientId, 'i1');
    });
  });
}
