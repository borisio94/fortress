// Un indicateur ne doit pas verdir parce qu'il manque des données.
//
// Le taux de food cost théorique divisait le coût des plats CHIFFRÉS par le
// chiffre d'affaires ENTIER. Les plats sans coût connu — typiquement les
// boissons, sans fiche recette ni prix d'achat saisi — apportaient donc du
// dénominateur sans apporter de numérateur : le taux baissait, et la carte
// annonçait une bonne maîtrise des matières.
//
// Le défaut s'aggravait à mesure que la donnée manquait. À 80 % de ventes non
// chiffrées, le taux tombait à 6 % : d'autant plus vert que le restaurant en
// savait moins sur ses coûts.
//
// Décision du 18/09/2026 : le taux se calcule sur les ventes DONT LE COÛT EST
// CONNU, et la couverture est exposée pour que l'écran puisse la dire.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/services/restaurant_reporting_service.dart';
import 'package:fortress/features/dashboard/data/dashboard_providers.dart'
    show DashRange;

RestaurantFinanceReport _report({
  double revenue = 1000000,
  double materialCost = 150000,
  double? coveredRevenue,
}) =>
    RestaurantFinanceReport(
      range: DashRange(DateTime(2026, 9, 1), DateTime(2026, 9, 30)),
      labels: const ['1/9'],
      revenue: revenue,
      materialCost: materialCost,
      coveredRevenue: coveredRevenue,
      charges: 0,
      losses: 0,
      payroll: 0,
      revenueSeries: const [0],
      expenseSeries: const [0],
      lossSeries: const [0],
      sectors: const [],
    );

void main() {
  group('Food cost théorique — périmètre du taux', () {
    test('la moitié des ventes sans coût ne divise pas le taux par deux', () {
      // 150 000 de coût sur 500 000 de ventes chiffrées, et 500 000 de ventes
      // dont on ne sait rien. Le taux vaut 30 %, pas 15 %.
      final r = _report(coveredRevenue: 500000);
      expect(r.theoreticalFoodCostRate, 30);
    });

    test('toutes les ventes chiffrées : le taux ne bouge pas', () {
      final r = _report(coveredRevenue: 1000000);
      expect(r.theoreticalFoodCostRate, 15);
    });

    test('la couverture est exposée', () {
      expect(_report(coveredRevenue: 500000).costCoverage, 0.5);
      expect(_report(coveredRevenue: 1000000).costCoverage, 1);
    });

    test('quatre ventes sur cinq sans coût : le taux ne tombe pas à 6 %', () {
      // C'est le cas qui rendait l'indicateur d'autant plus rassurant que la
      // donnée manquait.
      final r = _report(coveredRevenue: 200000, materialCost: 60000);
      expect(r.theoreticalFoodCostRate, 30);
      expect(r.costCoverage, closeTo(0.2, 1e-9));
    });

    test('aucune vente chiffrée ne produit ni NaN ni Infinity', () {
      final r = _report(coveredRevenue: 0, materialCost: 0);
      expect(r.theoreticalFoodCostRate, 0);
      expect(r.costCoverage, 0);
    });

    test('sans information de couverture, le taux reste sur tout le CA', () {
      // Repli : un appelant qui ne renseigne rien retrouve l'ancien calcul.
      expect(_report().theoreticalFoodCostRate, 15);
      expect(_report().costCoverage, 1);
    });
  });
}
