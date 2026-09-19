// Une avance déjà versée fait partie du coût du travail.
//
// `computeNet` retranche les avances : un employé qui a pris 50 000 F le 10
// touche 50 000 F au lieu de 100 000 F à la fin du mois. C'est juste pour LUI
// — il a déjà eu la moitié — mais le restaurant, lui, a bien dépensé 100 000 F.
//
// La masse salariale du bilan sommait les nets. Elle valait donc 250 000 F
// pour une équipe qui en avait coûté 300 000, et le bénéfice était surévalué
// du montant exact sorti en avance. L'argent était pourtant bien parti : la
// clôture de caisse le savait déjà (`StaffService.cashOut` compte les avances
// en espèces), le bilan l'ignorait.
//
// Décision du 18/09/2026 : la paie du bilan est le COÛT DU TRAVAIL, pas
// l'argent versé le jour de la paie. C'est aussi ce que rend l'estimation
// contractuelle du lot 4 — sans quoi le chiffre changeait de nature au moment
// où le gérant générait ses fiches.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/restaurant/domain/entities/payslip.dart';

Payslip _slip({int net = 0, int advances = 0}) => Payslip(
      id: 'pr_1',
      shopId: 's_1',
      employeeId: 'em_1',
      month: '2026-09',
      createdAt: DateTime(2026, 9, 30),
      baseSalary: 100000,
      advancesDeducted: advances,
      netSalary: net,
    );

void main() {
  group('Coût du travail d\'un bulletin', () {
    test('sans avance, le coût est le net versé', () {
      expect(_slip(net: 100000).laborCost, 100000);
    });

    test('une avance déduite revient dans le coût', () {
      // 50 000 pris le 10, 50 000 touchés à la fin : le restaurant a bien
      // dépensé 100 000.
      expect(_slip(net: 50000, advances: 50000).laborCost, 100000);
    });

    test('une avance égale au salaire laisse un net nul mais un coût entier',
        () {
      // `computeNet` plancher à zéro : le net ne peut pas être négatif. Le
      // coût, lui, reste ce qui est sorti.
      expect(_slip(net: 0, advances: 100000).laborCost, 100000);
    });

    test('le coût ne dépend pas du mode de paiement', () {
      // Espèces ou virement, l'argent est parti.
      expect(_slip(net: 50000, advances: 50000).laborCost,
          _slip(net: 100000).laborCost);
    });
  });
}
