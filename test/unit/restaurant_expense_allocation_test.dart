// Une dépense ne peut pas être comptée deux fois.
//
// Le bilan classe chaque dépense quotidienne dans UNE case et une seule : les
// achats de matières nourrissent la répartition du coût des plats, tout le
// reste pèse en charges d'exploitation. Les deux entrent dans le bénéfice.
//
// Le rattachement à un ingrédient ne suffisait pas à décider : la répartition
// retenait toute ligne portant un identifiant d'ingrédient, quelle que soit sa
// catégorie, pendant que le reporting comptait cette même ligne en
// exploitation parce qu'elle n'était pas un « achat marché ». Un transport de
// 30 000 F rattaché au poulet pesait donc 60 000 F sur le bénéfice.
//
// La règle est celle de la définition financière, section 1 : « matière si
// elle finit dans une assiette, exploitation sinon ». Le transport d'un
// ingrédient ne finit pas dans une assiette.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/services/daily_expense_service.dart';
import 'package:fortress/features/restaurant/domain/entities/daily_expense.dart';

DailyExpense _expense({required ExpenseKind kind, String? ingredientId}) =>
    DailyExpense(
      id: 'de_1',
      shopId: 's_1',
      description: 'ligne',
      amount: 30000,
      category: kind.key,
      ingredientId: ingredientId,
      expenseDate: DateTime(2026, 9, 18),
      createdAt: DateTime(2026, 9, 18),
    );

void main() {
  group('Répartition du coût matières — quelles dépenses y entrent', () {
    test('AUCUNE dépense n\'est à la fois répartie et charge d\'exploitation',
        () {
      // Exhaustif SUR TOUTES LES CATÉGORIES, et c'est le point : une catégorie
      // ajoutée demain sans y penser rouvrirait le double comptage. Le test
      // l'attrape sans qu'on ait à s'en souvenir.
      for (final kind in ExpenseKind.values) {
        final e = _expense(kind: kind, ingredientId: 'ig_poulet');
        final reparti = DailyExpenseService.feedsIngredientAllocation(e);
        // Le reporting compte en exploitation ce qui n'est pas du food cost et
        // n'est pas un remboursement de consigne.
        final exploitation = !e.isFoodCost && e.isCharge;
        expect(reparti && exploitation, isFalse,
            reason: '« ${kind.label} » serait comptée des deux côtés');
      }
    });

    test('un achat marché rattaché à un ingrédient est réparti', () {
      final e =
          _expense(kind: ExpenseKind.achatMarche, ingredientId: 'ig_poulet');
      expect(DailyExpenseService.feedsIngredientAllocation(e), isTrue);
    });

    test('un transport rattaché à un ingrédient reste une charge', () {
      // Le cas qui coûtait 30 000 F de bénéfice : rattaché au poulet, il
      // gonflait le coût du plat ET pesait en exploitation.
      final e = _expense(kind: ExpenseKind.transport, ingredientId: 'ig_poulet');
      expect(DailyExpenseService.feedsIngredientAllocation(e), isFalse);
      expect(!e.isFoodCost && e.isCharge, isTrue);
    });

    test('une FOURNITURE reste hors répartition, même en achat marché', () {
      // Aucun plat ne contient du gaz : son montant partirait entièrement en
      // « non réparti » et gonflerait l'écart qui sert à détecter le
      // gaspillage.
      final e =
          _expense(kind: ExpenseKind.achatMarche, ingredientId: 'si_barquette');
      expect(DailyExpenseService.feedsIngredientAllocation(e), isFalse);
    });

    test('une dépense sans rattachement n\'est jamais répartie', () {
      final e = _expense(kind: ExpenseKind.achatMarche);
      expect(DailyExpenseService.feedsIngredientAllocation(e), isFalse);
    });
  });
}
