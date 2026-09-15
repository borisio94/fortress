// Tests unitaires du bilan financier restaurant (module finances — Lot 3).
//
// `RestaurantReportingService.build()` lit Hive et n'est pas testable en
// unitaire ; ce qui est verrouillé ici, c'est l'ARITHMÉTIQUE du bilan, seule
// responsable des chiffres affichés sur le tableau de bord :
//   * la formule du bénéfice net (ventes − matières − charges − pertes − paie)
//     est celle de la spec ; une erreur de signe y annoncerait un bénéfice à
//     un restaurateur qui perd de l'argent ;
//   * `profitSeries` est DÉDUITE des trois autres séries : la courbe violette
//     ne peut pas raconter autre chose que les trois qu'elle surplombe ;
//   * les taux se divisent par le chiffre d'affaires — zéro vente ne doit
//     jamais produire NaN/Infinity à l'écran.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/services/restaurant_reporting_service.dart';
import 'package:fortress/features/dashboard/data/dashboard_providers.dart'
    show DashRange;

final _range = DashRange(DateTime(2026, 7, 1), DateTime(2026, 7, 3));

RestaurantFinanceReport _report({
  double revenue = 100000,
  double materialCost = 30000,
  int charges = 20000,
  int losses = 5000,
  int payroll = 0,
  List<double>? revenueSeries,
  List<double>? expenseSeries,
  List<double>? lossSeries,
  List<SectorLine> sectors = const [],
}) =>
    RestaurantFinanceReport(
      range: _range,
      labels: const ['1/7', '2/7', '3/7'],
      revenue: revenue,
      materialCost: materialCost,
      charges: charges,
      losses: losses,
      payroll: payroll,
      revenueSeries: revenueSeries ?? const [50000, 30000, 20000],
      expenseSeries: expenseSeries ?? const [20000, 20000, 10000],
      lossSeries: lossSeries ?? const [5000, 0, 0],
      sectors: sectors,
    );

SectorLine _sector({
  String? activityId = 'ra_1',
  String name = 'Chawarma',
  double revenue = 40000,
  double materialCost = 15000,
}) =>
    SectorLine(
      activityId: activityId,
      name: name,
      revenue: revenue,
      materialCost: materialCost,
      revenueSeries: const [40000, 0, 0],
      costSeries: const [15000, 0, 0],
    );

void main() {
  group('Bilan global — formules', () {
    test('dépenses = matières + charges + paie', () {
      final r = _report(materialCost: 30000, charges: 20000, payroll: 10000);
      expect(r.expenses, 60000);
    });

    test('bénéfice net = ventes − matières − charges − pertes − paie', () {
      // 100000 − 30000 − 20000 − 5000 − 10000 = 35000.
      final r = _report(payroll: 10000);
      expect(r.netProfit, 35000);
    });

    test('marge brute = ventes − matières, charges exclues', () {
      // La marge brute juge la CARTE ; les charges fixes ne dépendent pas des
      // plats vendus et ne doivent pas la contaminer.
      expect(_report().grossMargin, 70000);
    });

    test('un bénéfice peut être négatif', () {
      // Cas réel d'un mois creux : le loyer tombe, les ventes ne suivent pas.
      final r = _report(revenue: 10000, materialCost: 4000, charges: 150000);
      expect(r.netProfit, lessThan(0));
      expect(r.netProfit, 10000 - 4000 - 150000 - 5000);
    });

    test('la paie vaut 0 tant que PR-D n\'est pas livrée', () {
      // Le champ existe pour que la formule soit complète : elle ne changera
      // pas le jour où la paie arrivera.
      expect(_report().payroll, 0);
      expect(_report().netProfit, 45000);
    });
  });

  group('Taux de marge — division par zéro', () {
    test('sans vente, le taux vaut 0 et non NaN', () {
      final r = _report(revenue: 0, materialCost: 0, charges: 0, losses: 0);
      expect(r.marginRate, 0);
      expect(r.marginRate.isNaN, isFalse);
    });

    test('le taux est un pourcentage du chiffre d\'affaires', () {
      // 70000 / 100000 = 70 %.
      expect(_report().marginRate, 70);
    });

    test('un coût matières supérieur aux ventes donne un taux négatif', () {
      final r = _report(revenue: 10000, materialCost: 15000);
      expect(r.marginRate, -50);
    });
  });

  group('Séries du graphique', () {
    test('bénéfice par bucket = ventes − dépenses − pertes', () {
      final r = _report(
        revenueSeries: const [50000, 30000, 20000],
        expenseSeries: const [20000, 20000, 10000],
        lossSeries: const [5000, 0, 0],
      );
      expect(r.profitSeries, [25000, 10000, 10000]);
    });

    test('toutes les séries ont la longueur des libellés', () {
      // L'axe est commun : une série plus courte planterait le graphique.
      final r = _report();
      expect(r.revenueSeries.length, r.labels.length);
      expect(r.expenseSeries.length, r.labels.length);
      expect(r.lossSeries.length, r.labels.length);
      expect(r.profitSeries.length, r.labels.length);
    });

    test('un bucket déficitaire ressort en négatif', () {
      final r = _report(
        revenueSeries: const [0, 0, 0],
        expenseSeries: const [0, 150000, 0],
        lossSeries: const [0, 0, 0],
      );
      expect(r.profitSeries[1], -150000);
    });
  });

  group('Période sans activité', () {
    test('isEmpty quand rien n\'a bougé', () {
      final r = _report(revenue: 0, materialCost: 0, charges: 0, losses: 0);
      expect(r.isEmpty, isTrue);
    });

    test('une charge seule suffit à ne pas être vide', () {
      // Un loyer payé un mois sans vente EST une information financière.
      final r = _report(revenue: 0, materialCost: 0, charges: 150000, losses: 0);
      expect(r.isEmpty, isFalse);
    });

    test('une perte seule suffit à ne pas être vide', () {
      final r = _report(revenue: 0, materialCost: 0, charges: 0, losses: 3000);
      expect(r.isEmpty, isFalse);
    });
  });

  group('Résumé par secteur', () {
    test('marge et taux du secteur', () {
      final s = _sector(revenue: 40000, materialCost: 15000);
      expect(s.margin, 25000);
      expect(s.marginRate, closeTo(62.5, 0.001));
    });

    test('un secteur sans vente ne divise pas par zéro', () {
      final s = _sector(revenue: 0, materialCost: 0);
      expect(s.marginRate, 0);
    });

    test('activityId null identifie les ventes hors secteur', () {
      // Les plats non rattachés forment leur propre ligne, jamais un secteur
      // arbitraire (cf. D3).
      final s = _sector(
          activityId: null, name: RestaurantReportingService.noSectorLabel);
      expect(s.activityId, isNull);
      expect(s.name, 'Sans secteur');
    });

    test('les secteurs n\'incluent ni charges ni pertes', () {
      // Un loyer ne se découpe pas entre le bar et la cuisine : la ligne
      // secteur s'arrête à la marge brute.
      final r = _report(charges: 20000, losses: 5000, sectors: [_sector()]);
      final s = r.sectors.single;
      expect(s.margin, s.revenue - s.materialCost);
    });
  });
}
