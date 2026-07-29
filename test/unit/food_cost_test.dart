// Tests du bilan P&L et du food cost (Lot E).
//
// Ce qui est en jeu : le food cost est l'indicateur de survie d'un restaurant,
// et le bénéfice net est ce sur quoi le gérant décide d'ouvrir ou de fermer.
//
// LE PIÈGE de ce lot : deux mesures du coût des matières coexistent — le
// THÉORIQUE (fiches recettes × quantités vendues) et le RÉEL (achats au
// marché). Les additionner déduirait la matière DEUX FOIS et afficherait une
// perte à un restaurant rentable.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/services/restaurant_reporting_service.dart';
import 'package:fortress/features/dashboard/data/dashboard_providers.dart'
    show DashRange;
import 'package:fortress/features/restaurant/domain/entities/daily_expense.dart';

final _range = DashRange(DateTime(2026, 7, 1), DateTime(2026, 7, 31));

/// Catégories acceptées par le CHECK SQL de `daily_expenses.category`
/// (hotfix_149).
const _kSqlCategories = {
  'achat_marche',
  'consigne_rendue',
  'electricite',
  'gaz',
  'eau',
  'transport',
  'entretien',
  'personnel',
  'autre',
};

RestaurantFinanceReport _report({
  double revenue = 1000000,
  double materialCost = 300000,
  int realFoodCost = 0,
  int operatingCost = 0,
  int charges = 100000,
  int losses = 20000,
  int payroll = 0,
}) =>
    RestaurantFinanceReport(
      range: _range,
      labels: const ['1/7'],
      revenue: revenue,
      materialCost: materialCost,
      realFoodCost: realFoodCost,
      operatingCost: operatingCost,
      charges: charges,
      losses: losses,
      payroll: payroll,
      revenueSeries: const [1000000],
      expenseSeries: const [400000],
      lossSeries: const [20000],
      sectors: const [],
    );

void main() {
  group('Food cost — théorique vs réel', () {
    test('une saisie DÉRISOIRE ne fait pas basculer le bilan', () {
      // Le bug corrigé : 500 F d'achats saisis sur un mois où les ventes ont
      // consommé 300 000 F de matières faisait tomber le coût matières à 500 F
      // et le bénéfice explosait. Le seuil de couverture (50 %) l'empêche.
      final r = _report(materialCost: 300000, realFoodCost: 500);
      expect(r.usesRealFoodCost, isFalse);
      expect(r.partialFoodCostEntry, isTrue);
      expect(r.foodCost, 300000);
    });

    test('une saisie qui couvre la moitié du théorique bascule', () {
      final r = _report(materialCost: 300000, realFoodCost: 150000);
      expect(r.usesRealFoodCost, isTrue);
      expect(r.partialFoodCostEntry, isFalse);
      expect(r.foodCost, 150000);
    });

    test('sans fiches recettes, le réel est la seule mesure', () {
      // Aucun coût théorique calculable : on ne peut pas exiger une couverture
      // d'un chiffre qui n'existe pas.
      final r = _report(materialCost: 0, realFoodCost: 500);
      expect(r.usesRealFoodCost, isTrue);
    });

    test('sans achats saisis, le théorique fait foi', () {
      final r = _report(materialCost: 300000);
      expect(r.usesRealFoodCost, isFalse);
      expect(r.foodCost, 300000);
      expect(r.foodCostRate, closeTo(30, 0.001));
    });

    test('dès que des achats existent, le réel prend le relais', () {
      // C'est la question du restaurateur : « combien j'ai gagné », pas
      // « combien j'aurais dû gagner ».
      final r = _report(materialCost: 300000, realFoodCost: 380000);
      expect(r.usesRealFoodCost, isTrue);
      expect(r.partialFoodCostEntry, isFalse);
      expect(r.foodCost, 380000);
      expect(r.foodCostRate, closeTo(38, 0.001));
    });

    test('la matière n\'est JAMAIS comptée deux fois', () {
      // Le piège du lot : théorique 300 000 + réel 380 000 = 680 000 aurait
      // transformé un bénéfice de 500 000 en perte.
      final r = _report(
          revenue: 1000000,
          materialCost: 300000,
          realFoodCost: 380000,
          charges: 100000,
          losses: 20000);
      expect(r.expenses, 480000); // 380 000 + 100 000, pas 780 000
      expect(r.netProfit, 500000); // 1 000 000 − 480 000 − 20 000
    });

    test('les deux taux restent lisibles séparément', () {
      final r = _report(materialCost: 300000, realFoodCost: 380000);
      expect(r.theoreticalFoodCostRate, closeTo(30, 0.001));
      expect(r.realFoodCostRate, closeTo(38, 0.001));
    });

    test('l\'écart signale le gaspillage', () {
      // Acheté 380 000, consommé 300 000 par les ventes : 80 000 partis
      // ailleurs (stock, gaspillage, vol, ou recette fausse).
      final r = _report(materialCost: 300000, realFoodCost: 380000);
      expect(r.foodCostGap, 80000);
    });

    test('un écart négatif dit qu\'on puise dans le stock', () {
      final r = _report(materialCost: 300000, realFoodCost: 200000);
      expect(r.foodCostGap, -100000);
    });

    test('sans achats saisis, aucun écart n\'est affirmé', () {
      // Comparer un réel absent au théorique donnerait un écart de −300 000
      // et accuserait à tort une boutique qui ne saisit simplement pas ses
      // achats.
      expect(_report(materialCost: 300000).foodCostGap, 0);
    });
  });

  group('Seuils du food cost (spec Cameroun)', () {
    test('sous 30 % : bonne maîtrise', () {
      expect(_report(revenue: 1000000, materialCost: 250000).foodCostLevel,
          'good');
    });

    test('entre 30 et 35 % : à surveiller', () {
      expect(_report(revenue: 1000000, materialCost: 300000).foodCostLevel,
          'warning');
      expect(_report(revenue: 1000000, materialCost: 350000).foodCostLevel,
          'warning');
    });

    test('au-delà de 35 % : la carte ne couvre plus ses charges', () {
      expect(_report(revenue: 1000000, materialCost: 400000).foodCostLevel,
          'bad');
    });

    test('sans vente, aucun niveau n\'est affiché', () {
      // Un taux sans chiffre d'affaires ne veut rien dire : afficher une
      // pastille rouge un lundi matin serait un faux signal.
      expect(_report(revenue: 0, materialCost: 50000).foodCostLevel, isNull);
      expect(_report(revenue: 1000000, materialCost: 0).foodCostLevel, isNull);
    });

    test('les seuils sont ceux de la spec', () {
      expect(RestaurantFinanceReport.foodCostGood, 30);
      expect(RestaurantFinanceReport.foodCostWarning, 35);
    });
  });

  group('Bénéfice net', () {
    test('toutes les sorties sont déduites', () {
      // CA − matières − exploitation − charges − paie − pertes.
      final r = _report(
        revenue: 1000000,
        materialCost: 0,
        realFoodCost: 300000,
        operatingCost: 50000,
        charges: 100000,
        payroll: 200000,
        losses: 20000,
      );
      expect(r.expenses, 650000);
      expect(r.netProfit, 330000);
    });

    test('la masse salariale pèse sur le bénéfice', () {
      // Elle valait 0 en dur avant le Lot D : un restaurant avec 200 000 F de
      // salaires s'affichait bénéficiaire à tort.
      final sans = _report(payroll: 0);
      final avec = _report(payroll: 200000);
      expect(sans.netProfit - avec.netProfit, 200000);
    });

    test('la marge brute ignore les charges', () {
      // Elle mesure la carte, pas la structure : un loyer élevé ne doit pas
      // faire croire que les plats sont mal margés.
      final r = _report(revenue: 1000000, materialCost: 300000, charges: 900000);
      expect(r.grossMargin, 700000);
      expect(r.marginRate, closeTo(70, 0.001));
    });

    test('zéro vente ne produit ni NaN ni Infinity', () {
      final r = _report(revenue: 0, materialCost: 0, realFoodCost: 0);
      expect(r.foodCostRate, 0);
      expect(r.marginRate, 0);
      expect(r.theoreticalFoodCostRate, 0);
      expect(r.realFoodCostRate, 0);
    });
  });

  group('DailyExpense', () {
    DailyExpense expense({
      ExpenseKind kind = ExpenseKind.achatMarche,
      int amount = 12000,
      bool isCash = true,
    }) =>
        DailyExpense(
          id: 'de_1',
          shopId: 'shop_1',
          description: 'Poisson',
          amount: amount,
          category: kind.key,
          isCash: isCash,
          paidBy: 'Awa',
          expenseDate: DateTime(2026, 7, 15),
          createdAt: DateTime(2026, 7, 15),
        );

    test('les catégories émises existent côté SQL', () {
      for (final k in ExpenseKind.values) {
        expect(_kSqlCategories, contains(k.key),
            reason: '« ${k.key} » absente du CHECK SQL');
      }
    });

    test('seul l\'achat au marché est du food cost', () {
      for (final k in ExpenseKind.values) {
        expect(k.isFoodCost, k == ExpenseKind.achatMarche,
            reason: '${k.label} ne devrait pas compter comme matière');
      }
    });

    test('aller-retour toMap/fromMap sans perte', () {
      final back = DailyExpense.fromMap(expense().toMap());
      expect(back.description, 'Poisson');
      expect(back.amount, 12000);
      expect(back.kind, ExpenseKind.achatMarche);
      expect(back.paidBy, 'Awa');
      expect(back.isCash, isTrue);
      expect(back.isFoodCost, isTrue);
    });

    test('une catégorie inconnue est normalisée', () {
      // Hors CHECK, l'upsert serait rejeté par Postgres et l'op droppée après
      // dix essais, sans bruit.
      final raw = expense().toMap()..['category'] = 'cryptomonnaie';
      expect(DailyExpense.fromMap(raw).kind, ExpenseKind.autre);
    });

    test('une dépense hors espèces ne sort pas du tiroir', () {
      expect(expense(isCash: false).isCash, isFalse);
    });
  });
}
