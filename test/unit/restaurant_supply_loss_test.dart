// Une fourniture manquante ne se paie pas deux fois.
//
// Un réassort de barquettes entre en charge d'exploitation. L'inventaire
// constate ensuite qu'il en manque : cet écart tombait en perte, À SON
// MONTANT, alors que les barquettes manquantes font partie de celles déjà
// payées. 30 000 F d'achats plus 8 000 F de manque retiraient 38 000 F du
// bénéfice pour 30 000 F dépensés.
//
// Les INGRÉDIENTS ne connaissent pas ce défaut : leur manque est retiré des
// achats avant partage, plafonné à ces achats — la voie (b) du document,
// « coût matière + pertes = achats ». Seules les fournitures en étaient
// exclues, parce qu'elles ne sont pas réparties sur les plats.
//
// Décision du 19/09/2026 : même règle pour elles. Le manque sort des achats,
// et la perte vaut ce qui en a été retiré.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/services/daily_expense_service.dart';
import 'package:fortress/core/services/restaurant_reporting_service.dart';
import 'package:fortress/features/restaurant/domain/entities/daily_expense.dart';

DailyExpense _expense({required ExpenseKind kind, String? attached}) =>
    DailyExpense(
      id: 'de_1',
      shopId: 's_1',
      description: 'ligne',
      amount: 30000,
      category: kind.key,
      ingredientId: attached,
      expenseDate: DateTime(2026, 9, 18),
      createdAt: DateTime(2026, 9, 18),
    );

void main() {
  group('Achats de fournitures — ce qui alimente la déduction', () {
    test('un réassort de barquettes est bien un achat de fourniture', () {
      final e = _expense(kind: ExpenseKind.autre, attached: 'si_barquette');
      expect(DailyExpenseService.feedsSupplyDeduction(e), isTrue);
    });

    test('un INGRÉDIENT n\'est pas une fourniture', () {
      // Lui relève de la répartition, avec son propre mécanisme de retrait.
      final e =
          _expense(kind: ExpenseKind.achatMarche, attached: 'ig_poulet');
      expect(DailyExpenseService.feedsSupplyDeduction(e), isFalse);
    });

    test('une dépense sans rattachement n\'est pas une fourniture', () {
      expect(
          DailyExpenseService.feedsSupplyDeduction(
              _expense(kind: ExpenseKind.electricite)),
          isFalse);
    });

    test('un remboursement de consigne n\'est pas une charge, donc pas ici',
        () {
      // Le client récupère son argent : ce n'est pas un achat du restaurant.
      final e = _expense(
          kind: ExpenseKind.consigneRendue, attached: 'si_bouteille');
      expect(DailyExpenseService.feedsSupplyDeduction(e), isFalse);
    });

    test('AUCUNE dépense ne nourrit à la fois les deux déductions', () {
      // Exhaustif : une catégorie ajoutée demain ne doit pas pouvoir être
      // retirée deux fois — une fois des plats, une fois de l'exploitation.
      for (final kind in ExpenseKind.values) {
        for (final id in ['ig_poulet', 'si_barquette', null]) {
          final e = _expense(kind: kind, attached: id);
          final rep = DailyExpenseService.feedsIngredientAllocation(e);
          final sup = DailyExpenseService.feedsSupplyDeduction(e);
          expect(rep && sup, isFalse,
              reason: '« ${kind.label} » + $id serait déduite deux fois');
        }
      }
    });
  });

  group('Manque de fourniture — plafonné aux achats de la période', () {
    test('le manque sort des achats, à concurrence de ce qui a été acheté',
        () {
      // 30 000 de barquettes achetées, 8 000 manquantes : 8 000 retirés de la
      // charge d'exploitation, qui retombe à 22 000. Avec la perte à 8 000, le
      // total reste 30 000 — l'identité « charge + pertes = achats ».
      final out = RestaurantReportingService.supplyWithdrawalsOf(
        requests: const {'si_barquette': 8000},
        purchases: const {'si_barquette': 30000},
      );
      expect(out['si_barquette'], 8000);
    });

    test('un manque plus gros que les achats est PLAFONNÉ', () {
      // Sinon la charge deviendrait négative et le bénéfice gonflerait d'un
      // stock qui n'a jamais été acheté sur la période.
      final out = RestaurantReportingService.supplyWithdrawalsOf(
        requests: const {'si_barquette': 40000},
        purchases: const {'si_barquette': 30000},
      );
      expect(out['si_barquette'], 30000);
    });

    test('une fourniture jamais achetée ne retire rien', () {
      final out = RestaurantReportingService.supplyWithdrawalsOf(
        requests: const {'si_gaz': 5000},
        purchases: const {'si_barquette': 30000},
      );
      expect(out['si_gaz'] ?? 0, 0);
    });

    test('chaque fourniture est plafonnée séparément', () {
      final out = RestaurantReportingService.supplyWithdrawalsOf(
        requests: const {'si_barquette': 8000, 'si_gaz': 20000},
        purchases: const {'si_barquette': 30000, 'si_gaz': 12000},
      );
      expect(out['si_barquette'], 8000);
      expect(out['si_gaz'], 12000);
    });

    test('aucun manque déclaré ne retire rien', () {
      expect(
          RestaurantReportingService.supplyWithdrawalsOf(
              requests: const {}, purchases: const {'si_barquette': 30000}),
          isEmpty);
    });
  });
}
