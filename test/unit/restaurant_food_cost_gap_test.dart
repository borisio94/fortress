// Un écart entre achats et consommation ne prouve pas un gaspillage.
//
// En mode RÉPARTITION, le coût théorique est dérivé des achats eux-mêmes.
// L'identité du module le dit : « vendu + perdu + non réparti + retiré =
// acheté ». L'écart achats − théorique ne peut donc rien révéler sur le
// gaspillage : celui-ci est déjà sorti en pertes, et ce qui reste est du
// NON-RATTACHEMENT — des achats qu'aucun plat vendu ne consomme.
//
// L'écran annonçait pourtant « stock constitué, gaspillage ou fiche recette à
// revoir ». Trois causes, dont deux fausses, et le gérant partait chercher un
// voleur là où il suffisait de rattacher un ingrédient.
//
// Décision du 19/09/2026 : l'écart est DÉCOMPOSÉ. La part qui s'explique par
// des achats non rattachés est nommée pour ce qu'elle est.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/services/restaurant_reporting_service.dart';
import 'package:fortress/features/dashboard/data/dashboard_providers.dart'
    show DashRange;

RestaurantFinanceReport _report({
  double materialCost = 150000,
  int realFoodCost = 200000,
  int unallocated = 0,
}) =>
    RestaurantFinanceReport(
      range: DashRange(DateTime(2026, 9, 1), DateTime(2026, 9, 30)),
      labels: const ['1/9'],
      revenue: 1000000,
      materialCost: materialCost,
      realFoodCost: realFoodCost,
      unallocatedPurchases: unallocated,
      charges: 0,
      losses: 0,
      payroll: 0,
      revenueSeries: const [0],
      expenseSeries: const [0],
      lossSeries: const [0],
      sectors: const [],
    );

void main() {
  group('Écart achats / consommation — ce qu\'il mesure', () {
    test('un écart entièrement dû au non-rattachement est nommé comme tel', () {
      // 200 000 d'achats, 150 000 imputés aux plats vendus, 50 000 sur un
      // ingrédient qu'aucun plat vendu ne contient.
      final r = _report(unallocated: 50000);
      expect(r.foodCostGap, 50000);
      expect(r.gapFromUnallocated, 50000);
      expect(r.gapBeyondUnallocated, 0);
    });

    test('sans achat non rattaché, tout l\'écart reste à expliquer', () {
      final r = _report(materialCost: 150000, realFoodCost: 200000);
      expect(r.foodCostGap, 50000);
      expect(r.gapFromUnallocated, 0);
      expect(r.gapBeyondUnallocated, 50000);
    });

    test('un écart partiellement expliqué se décompose', () {
      // 30 000 de non-rattaché sur 50 000 d'écart : 20 000 restent ouverts.
      final r = _report(unallocated: 30000);
      expect(r.gapFromUnallocated, 30000);
      expect(r.gapBeyondUnallocated, 20000);
    });

    test('le non-rattaché ne dépasse jamais l\'écart lui-même', () {
      // Des pertes peuvent rendre l'écart plus petit que le non-rattaché ;
      // annoncer plus que l'écart affiché serait incompréhensible.
      final r = _report(materialCost: 190000, unallocated: 50000);
      expect(r.foodCostGap, 10000);
      expect(r.gapFromUnallocated, 10000);
      expect(r.gapBeyondUnallocated, 0);
    });

    test('sans achats saisis, il n\'y a pas d\'écart du tout', () {
      // Le bilan reste au théorique : comparer n'aurait aucun sens.
      final r = _report(realFoodCost: 0, unallocated: 50000);
      expect(r.foodCostGap, 0);
      expect(r.gapFromUnallocated, 0);
    });
  });
}
