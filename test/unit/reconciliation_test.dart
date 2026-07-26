// Tests unitaires de la réconciliation d'inventaire (module finances — Lot 2).
//
// La règle D4 est isolée dans `ReconciliationService.decide()`, fonction PURE :
// c'est elle qui décide si un écart corrige le stock et s'il crée une perte.
// `apply()` ne fait que l'exécuter (Hive + LossService), donc verrouiller
// `decide()` verrouille le comportement métier.
//
// Ce qui est en jeu à chaque règle :
//   * un surplus qui créerait une perte → `losses.amount` étant un entier
//     positif, la perte serait comptée À L'ENVERS et gonflerait le total des
//     pertes au lieu de le réduire ;
//   * un écart nul qui écrirait quand même → une perte à 0 F par article et
//     par inventaire, l'onglet Pertes devient illisible ;
//   * un manque qui ne corrigerait pas le stock → le stock théorique reste
//     faux et le prochain inventaire reconstate le même écart.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/services/reconciliation_service.dart';

CountableItem _item({
  String name = 'Riz',
  double theoretical = 10,
  int costPerUnit = 500,
  bool isIngredient = true,
}) =>
    CountableItem(
      id: isIngredient ? 'ig_1' : 'si_1',
      name: name,
      unit: 'kg',
      theoretical: theoretical,
      costPerUnit: costPerUnit,
      isIngredient: isIngredient,
    );

StockVariance _variance({double theoretical = 10, double actual = 10,
        int costPerUnit = 500}) =>
    StockVariance(
      item: _item(theoretical: theoretical, costPerUnit: costPerUnit),
      actual: actual,
    );

void main() {
  group('Écart — calcul et signe', () {
    test('manque : variance négative, impact valorisé', () {
      final v = _variance(theoretical: 10, actual: 8);
      expect(v.variance, -2);
      expect(v.isShortage, isTrue);
      expect(v.isSurplus, isFalse);
      // 2 kg manquants × 500 F = 1000 F, toujours positif.
      expect(v.financialImpact, 1000);
      expect(v.label, 'Perte / sur-dosage');
    });

    test('surplus : variance positive, impact valorisé aussi', () {
      final v = _variance(theoretical: 10, actual: 12);
      expect(v.variance, 2);
      expect(v.isSurplus, isTrue);
      expect(v.isShortage, isFalse);
      // L'impact est informatif ; il ne deviendra PAS une perte (cf. plus bas).
      expect(v.financialImpact, 1000);
      expect(v.label, 'Sous-dosage');
    });

    test('conforme : ni manque ni surplus', () {
      final v = _variance(theoretical: 10, actual: 10);
      expect(v.variance, 0);
      expect(v.isShortage, isFalse);
      expect(v.isSurplus, isFalse);
      expect(v.financialImpact, 0);
      expect(v.label, 'Conforme');
    });

    test('un écart fractionnaire est arrondi au franc', () {
      // 0,5 kg × 333 F = 166,5 → 167 F. Les montants de perte sont des
      // entiers en base (`losses.amount`), l'arrondi doit être explicite.
      final v = _variance(theoretical: 10, actual: 9.5, costPerUnit: 333);
      expect(v.financialImpact, 167);
    });

    test('stock tombé à zéro : tout le théorique est perdu', () {
      final v = _variance(theoretical: 4, actual: 0);
      expect(v.variance, -4);
      expect(v.financialImpact, 2000);
    });
  });

  group('Règle D4 — ce que décide un écart', () {
    test('un manque corrige le stock ET crée une perte', () {
      final d = ReconciliationService.decide(_variance(theoretical: 10, actual: 8));
      expect(d.adjustStock, isTrue);
      expect(d.createsLoss, isTrue);
      expect(d.lossAmount, 1000);
    });

    test('un surplus corrige le stock SANS créer de perte', () {
      // Le point central de D4 : `losses.amount` est un entier positif, une
      // perte de surplus serait comptée à l'envers dans tous les cumuls.
      final d = ReconciliationService.decide(_variance(theoretical: 10, actual: 12));
      expect(d.adjustStock, isTrue);
      expect(d.createsLoss, isFalse);
      expect(d.lossAmount, 0);
    });

    test('un écart nul n\'écrit rien du tout', () {
      final d = ReconciliationService.decide(_variance(theoretical: 10, actual: 10));
      expect(d.adjustStock, isFalse);
      expect(d.createsLoss, isFalse);
    });

    test('un manque sans coût unitaire corrige le stock sans perte à 0 F', () {
      // Coût non renseigné : la correction de stock reste utile, mais une
      // perte à 0 F ne serait que du bruit dans l'onglet Pertes.
      final d = ReconciliationService.decide(
          _variance(theoretical: 10, actual: 8, costPerUnit: 0));
      expect(d.adjustStock, isTrue);
      expect(d.createsLoss, isFalse);
    });

    test('la règle est identique pour un article de stock', () {
      // Un ingrédient et une boisson se comptent pareil — la décision ne doit
      // pas dépendre du type d'article.
      final bottle = StockVariance(
        item: _item(name: 'Bière', isIngredient: false),
        actual: 8,
      );
      final d = ReconciliationService.decide(bottle);
      expect(d.adjustStock, isTrue);
      expect(d.lossAmount, 1000);
    });
  });

  group('Traçabilité de la perte', () {
    test('la catégorie est celle du CHECK SQL étendu par hotfix_141', () {
      // Une valeur hors CHECK ferait rejeter l'upsert par Postgres, et l'op
      // serait droppée après 10 essais — silencieusement.
      expect(ReconciliationService.lossCategory, 'ecart_inventaire');
    });

    test('la provenance suit le format documenté par Loss.origin', () {
      expect(ReconciliationService.originFor('Riz'), 'réconciliation: Riz');
    });
  });
}
