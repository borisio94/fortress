// Une heure supplémentaire payée le soir même est du coût du travail.
//
// Le gérant tranche en fin de service : payées de suite, ou reportées sur la
// paie du mois. « Payées de suite » sort l'argent du tiroir immédiatement et
// marque le pointage soldé — ces heures n'entrent donc JAMAIS dans une fiche
// de paie, et c'est voulu.
//
// Mais le bilan sommait les fiches. Cet argent, bien sorti, n'apparaissait
// nulle part en charge : la masse salariale était sous-évaluée et le bénéfice
// surévalué d'autant. La clôture de caisse, elle, le savait déjà —
// `cashOut` le déduit pour ne pas crier au manquant.
//
// C'est exactement la maladie des avances, refermée au lot 5, et la même
// décision s'applique : la paie du bilan est le COÛT DU TRAVAIL, pas l'argent
// versé le jour de la paie.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/services/staff_service.dart';
import 'package:fortress/features/restaurant/domain/entities/time_record.dart';
import 'package:fortress/features/restaurant/domain/entities/shift_evaluation.dart';

TimeRecord _record({
  required DateTime out,
  int amount = 5000,
  OvertimeSettlement how = OvertimeSettlement.paidNow,
  bool settled = true,
  int minutes = 60,
}) =>
    TimeRecord(
      id: 'tr_${out.day}_$amount',
      shopId: 's_1',
      employeeId: 'em_1',
      createdAt: out,
      clockOut: out,
      overtimeMinutes: minutes,
      overtimeAmount: amount,
      overtimeSettlement: how,
      overtimeSettled: settled,
    );

void main() {
  group('Heures supplémentaires payées en espèces', () {
    test('une heure payée de suite compte dans le mois de sa SORTIE', () {
      final r = [_record(out: DateTime(2026, 9, 18, 23, 30))];
      expect(StaffService.overtimePaidInCashFor(r, '2026-09'), 5000);
    });

    test('plusieurs soirées s\'additionnent', () {
      final r = [
        _record(out: DateTime(2026, 9, 5), amount: 3000),
        _record(out: DateTime(2026, 9, 12), amount: 4000),
      ];
      expect(StaffService.overtimePaidInCashFor(r, '2026-09'), 7000);
    });

    test('celles REPORTÉES sur la paie ne comptent pas ici', () {
      // Elles entreront dans le net de la fiche : les compter deux fois
      // doublerait la charge.
      final r = [
        _record(
            out: DateTime(2026, 9, 10),
            how: OvertimeSettlement.onPayslip,
            settled: false),
      ];
      expect(StaffService.overtimePaidInCashFor(r, '2026-09'), 0);
    });

    test('celles en ATTENTE de décision ne comptent pas', () {
      final r = [
        _record(
            out: DateTime(2026, 9, 10),
            how: OvertimeSettlement.pending,
            settled: false),
      ];
      expect(StaffService.overtimePaidInCashFor(r, '2026-09'), 0);
    });

    test('un autre mois ne compte pas', () {
      final r = [_record(out: DateTime(2026, 8, 31, 22, 0), amount: 9000)];
      expect(StaffService.overtimePaidInCashFor(r, '2026-09'), 0);
    });

    test('une nuit à cheval compte au mois où elle se TERMINE', () {
      // Service commencé le 31 août à 21 h, fini le 1er septembre à 2 h :
      // c'est la nuit qui a été payée, pas la soirée.
      final r = [_record(out: DateTime(2026, 9, 1, 2, 0), amount: 6000)];
      expect(StaffService.overtimePaidInCashFor(r, '2026-09'), 6000);
      expect(StaffService.overtimePaidInCashFor(r, '2026-08'), 0);
    });

    test('un pointage sans heure supplémentaire ne compte pas', () {
      final r = [_record(out: DateTime(2026, 9, 10), minutes: 0, amount: 0)];
      expect(StaffService.overtimePaidInCashFor(r, '2026-09'), 0);
    });
  });
}
