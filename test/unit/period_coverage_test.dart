// Le nom d'une période ne dit pas ce qu'elle couvre.
//
// « Mois » a valu trente jours glissants sans que personne le sache ; « Année »
// vaut les douze derniers mois. La feuille de choix écrit donc les dates à côté
// du nom, calculées depuis la même fenêtre que les chiffres.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/dashboard/data/dashboard_providers.dart';
import 'package:fortress/features/restaurant/domain/period_coverage.dart';

void main() {
  final now = DateTime(2026, 9, 24, 15, 30);

  group('Plage de jours', () {
    test('le mois en cours se lit du 1er à aujourd\'hui', () {
      final r = DashRange(DateTime(2026, 9), DateTime(2026, 9, 25));
      expect(formatCoverageRange(r, now: now), '1er → 24 sept.');
    });

    test('la borne de fin est exclue : on affiche la veille', () {
      final r = DashRange(DateTime(2026, 9, 18), DateTime(2026, 9, 25));
      expect(formatCoverageRange(r, now: now), '18 → 24 sept.');
    });

    test('un jour seul ne s\'écrit pas comme un intervalle', () {
      final r = DashRange(DateTime(2026, 9, 23), DateTime(2026, 9, 24));
      expect(formatCoverageRange(r, now: now), '23 sept.');
    });

    test('deux mois de la même année', () {
      final r = DashRange(DateTime(2026, 8, 18), DateTime(2026, 9, 25));
      expect(formatCoverageRange(r, now: now), '18 août → 24 sept.');
    });

    test('à cheval sur deux années, chaque borne porte la sienne', () {
      final r = DashRange(DateTime(2025, 10), DateTime(2026, 9, 25));
      expect(formatCoverageRange(r, now: now), '1er oct. 2025 → 24 sept. 2026');
    });

    test('une plage d\'une autre année garde son année', () {
      final r = DashRange(DateTime(2025, 3, 2), DateTime(2025, 3, 11));
      expect(formatCoverageRange(r, now: now), '2 → 10 mars 2025');
    });
  });

  group('Couverture par période', () {
    test('la semaine se dit glissante, pas en dates', () {
      final r = DashRange(DateTime(2026, 9, 18), DateTime(2026, 9, 25));
      expect(periodCoverage(DashPeriod.week, r, now: now), '7 derniers jours');
    });

    test('le mois est le mois civil, écrit en dates', () {
      final r = rangeFor(DashPeriod.month);
      final txt = periodCoverage(DashPeriod.month, r, now: DateTime.now());
      expect(txt, startsWith('1er'));
    });
  });
}
