// Une paie mensuelle ne tombe pas entière sur une journée.
//
// Le bilan imputait la paie de CHAQUE mois touché par la fenêtre, pour son
// montant entier. « Aujourd'hui » retirait donc un salaire mensuel complet du
// bénéfice, et une fenêtre à cheval sur deux mois en retirait deux — y compris
// celle qui s'appelle « Mois », qui vaut 30 jours glissants et chevauche
// presque toujours.
//
// La règle retenue le 18/09/2026 : la paie d'un mois se répartit sur ses
// jours, et la fenêtre en prend sa part. C'est le seul calcul qui vaille quelle
// que soit la fenêtre, y compris les 30 jours glissants d'aujourd'hui — il ne
// dépend d'aucun seuil à deviner.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/services/restaurant_reporting_service.dart';
import 'package:fortress/features/dashboard/data/dashboard_providers.dart'
    show DashRange;

void main() {
  group('Paie au prorata des jours couverts', () {
    test('« aujourd\'hui » ne porte qu\'un jour de paie', () {
      // La fenêtre du jour va de minuit à minuit le lendemain. Compter ce
      // lendemain donnerait deux jours pour une journée.
      final range =
          DashRange(DateTime(2026, 9, 18), DateTime(2026, 9, 19));
      expect(RestaurantReportingService.payrollShareOf('2026-09', range),
          closeTo(1 / 30, 1e-9));
    });

    test('sept jours de septembre valent 7/30 de la paie', () {
      final range =
          DashRange(DateTime(2026, 9, 12), DateTime(2026, 9, 19));
      expect(RestaurantReportingService.payrollShareOf('2026-09', range),
          closeTo(7 / 30, 1e-9));
    });

    test('un mois entier vaut la paie entière', () {
      final range = DashRange(DateTime(2026, 9, 1), DateTime(2026, 10, 1));
      expect(RestaurantReportingService.payrollShareOf('2026-09', range), 1);
    });

    test('une fenêtre À CHEVAL ne compte pas deux paies entières', () {
      // Le cas de la fenêtre « Mois » : 30 jours glissants du 20 août au
      // 18 septembre. Elle touche deux mois, et comptait donc DEUX salaires
      // mensuels complets — 600 000 F là où il en est sorti 300 000.
      final range =
          DashRange(DateTime(2026, 8, 20), DateTime(2026, 9, 19));
      final aout = RestaurantReportingService.payrollShareOf('2026-08', range);
      final sept = RestaurantReportingService.payrollShareOf('2026-09', range);
      expect(aout, closeTo(12 / 31, 1e-9));
      expect(sept, closeTo(18 / 30, 1e-9));
      // La somme des parts approche UN mois, jamais deux.
      expect(aout + sept, lessThan(1.05));
      expect(aout + sept, greaterThan(0.9));
    });

    test('un mois hors fenêtre ne coûte rien', () {
      final range =
          DashRange(DateTime(2026, 9, 1), DateTime(2026, 9, 30));
      expect(RestaurantReportingService.payrollShareOf('2026-07', range), 0);
    });

    test('février compte 28 jours, pas 30', () {
      // Le prorata se prend sur les jours RÉELS du mois : une journée de
      // février pèse plus lourd qu'une journée de janvier.
      final range = DashRange(DateTime(2026, 2, 10), DateTime(2026, 2, 11));
      expect(RestaurantReportingService.payrollShareOf('2026-02', range),
          closeTo(1 / 28, 1e-9));
    });
  });
}
