// Absences décidées : mise à pied et congé payé (hotfix_166).
//
// Ce qui est en jeu : une retenue de trop, c'est un employé amputé de jours
// qu'il n'a pas manqués ; une retenue oubliée, c'est une sanction sans effet.
// Et une absence à cheval sur deux mois est exactement le cas où l'on se
// trompe — le calendrier, lui, ne se discute pas.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/restaurant/domain/entities/payslip.dart';
import 'package:fortress/features/restaurant/domain/entities/staff_absence.dart';

void main() {
  group('StaffAbsence.days', () {
    test('les bornes sont INCLUSES', () {
      // « Du 10 au 12 » se compte trois jours pour tout le monde.
      expect(_absence(start: (2026, 8, 10), end: (2026, 8, 12)).days, 3);
    });

    test('une absence d\'un seul jour vaut un jour', () {
      expect(_absence(start: (2026, 8, 10), end: (2026, 8, 10)).days, 1);
    });

    test('une fin saisie avant le début vaut un jour, pas une durée négative',
        () {
      expect(_absence(start: (2026, 8, 12), end: (2026, 8, 10)).days, 1);
    });

    test('l\'heure de saisie ne change pas le compte', () {
      final a = StaffAbsence(
        id: 'ab_1',
        shopId: 'shop_1',
        employeeId: 'em_1',
        kind: AbsenceKind.suspension,
        startDate: DateTime(2026, 8, 10, 23, 59),
        endDate: DateTime(2026, 8, 12, 0, 1),
        reason: 'x',
        createdAt: DateTime(2026, 8, 10),
      );
      expect(a.days, 3);
    });
  });

  group('StaffAbsence.coversDay', () {
    final a = _absence(start: (2026, 8, 10), end: (2026, 8, 12));

    test('couvre le premier et le dernier jour', () {
      expect(a.coversDay(DateTime(2026, 8, 10)), isTrue);
      expect(a.coversDay(DateTime(2026, 8, 12, 22, 0)), isTrue);
    });

    test('ne couvre ni la veille ni le lendemain', () {
      expect(a.coversDay(DateTime(2026, 8, 9, 23, 59)), isFalse);
      expect(a.coversDay(DateTime(2026, 8, 13)), isFalse);
    });

    test('une absence LEVÉE ne couvre plus rien', () {
      // C'est ce qui rend le badge de nouveau possible : sans ça, lever une
      // mise à pied ne servirait à rien tant que la période court.
      final lifted = a.copyWith(cancelledAt: DateTime(2026, 8, 11));
      expect(lifted.coversDay(DateTime(2026, 8, 11)), isFalse);
    });
  });

  group('StaffAbsence.daysInMonth', () {
    test('une absence à cheval se répartit sur les deux mois', () {
      // Le cas où l'on se trompe : sans découpage, la retenue entière
      // tomberait sur le mois de départ et le bulletin suivant serait faux.
      final a = _absence(start: (2026, 8, 28), end: (2026, 9, 3));
      expect(a.days, 7);
      expect(a.daysInMonth('2026-08'), 4); // 28, 29, 30, 31
      expect(a.daysInMonth('2026-09'), 3); // 1, 2, 3
      expect(a.daysInMonth('2026-08') + a.daysInMonth('2026-09'), a.days);
    });

    test('un mois sans recoupement ne compte rien', () {
      final a = _absence(start: (2026, 8, 10), end: (2026, 8, 12));
      expect(a.daysInMonth('2026-07'), 0);
      expect(a.daysInMonth('2026-09'), 0);
    });

    test('une année bissextile ne décale rien', () {
      final a = _absence(start: (2028, 2, 27), end: (2028, 3, 1));
      expect(a.daysInMonth('2028-02'), 3); // 27, 28, 29
      expect(a.daysInMonth('2028-03'), 1);
    });
  });

  group('StaffAbsence.dailyRate', () {
    test('le salaire mensuel divisé par 30', () {
      // Trente et non le nombre réel de jours : même retenue en février qu'en
      // mars pour une même absence, ce qu'un employé comprend.
      expect(StaffAbsence.dailyRate(90000), 3000);
      expect(StaffAbsence.dailyRate(80000), 2667);
    });

    test('sans salaire renseigné, aucune retenue possible', () {
      expect(StaffAbsence.dailyRate(0), 0);
      expect(StaffAbsence.dailyRate(-1), 0);
    });
  });

  group('StaffAbsence — mise à pied SANS solde', () {
    final a = _absence(
        start: (2026, 8, 10), end: (2026, 8, 12), kind: AbsenceKind.suspension);

    test('le salaire est amputé au prorata des jours', () {
      expect(a.hitsPayroll, isTrue);
      expect(a.totalDeduction(90000), 9000); // 3 j × 3 000
      expect(a.dueFor('2026-08', 90000), 9000);
    });

    test('rien sur un mois qu\'elle ne touche pas', () {
      expect(a.dueFor('2026-09', 90000), 0);
    });

    test('la retenue déjà portée n\'est pas reprise', () {
      // Sans ce plafond, régénérer une fiche retiendrait deux fois les mêmes
      // journées.
      final taken = a.deduct(9000);
      expect(taken.remaining(90000), 0);
      expect(taken.dueFor('2026-08', 90000), 0);
    });

    test('à cheval sur deux mois, chaque paie porte SA part', () {
      final long = _absence(
          start: (2026, 8, 28),
          end: (2026, 9, 3),
          kind: AbsenceKind.suspension);
      final firstDue = long.dueFor('2026-08', 90000);
      expect(firstDue, 12000); // 4 j
      final after = long.deduct(firstDue);
      expect(after.dueFor('2026-09', 90000), 9000); // 3 j
      expect(after.deduct(9000).remaining(90000), 0);
    });
  });

  group('StaffAbsence — ce qui ne touche PAS le salaire', () {
    test('un congé payé ne retient jamais rien', () {
      final a = _absence(
          start: (2026, 8, 10),
          end: (2026, 8, 20),
          kind: AbsenceKind.paidLeave);
      expect(a.isPaid, isTrue);
      expect(a.hitsPayroll, isFalse);
      expect(a.dueFor('2026-08', 90000), 0);
    });

    test('une mise à pied CONSERVATOIRE non plus', () {
      // Écarter le temps de vérifier les faits ne doit pas sanctionner avant
      // d'avoir vérifié.
      final a = _absence(
              start: (2026, 8, 10),
              end: (2026, 8, 12),
              kind: AbsenceKind.suspension)
          .copyWith(isPaid: true);
      expect(a.hitsPayroll, isFalse);
      expect(a.dueFor('2026-08', 90000), 0);
    });

    test('une mise à pied LEVÉE non plus', () {
      final a = _absence(
              start: (2026, 8, 10),
              end: (2026, 8, 12),
              kind: AbsenceKind.suspension)
          .copyWith(cancelledAt: DateTime(2026, 8, 11));
      expect(a.hitsPayroll, isFalse);
      expect(a.dueFor('2026-08', 90000), 0);
    });
  });

  group('StaffAbsence — sérialisation', () {
    test('aller-retour sans perte', () {
      final a = _absence(
              start: (2026, 8, 10),
              end: (2026, 8, 12),
              kind: AbsenceKind.suspension)
          .deduct(9000);
      final back = StaffAbsence.fromMap(a.toMap());
      expect(back.kind, AbsenceKind.suspension);
      expect(back.startDate, DateTime(2026, 8, 10));
      expect(back.endDate, DateTime(2026, 8, 12));
      expect(back.isPaid, isFalse);
      expect(back.amountDeducted, 9000);
      expect(back.reason, 'Absence répétée sans prévenir');
    });

    test('un congé payé relu reste payé, même si le drapeau dit le contraire',
        () {
      // Une ligne corrompue ne doit pas pouvoir amputer un salaire : le congé
      // payé l'est par définition, la donnée stockée ne peut pas le
      // contredire.
      final back = StaffAbsence.fromMap({
        'id': 'ab_1',
        'shop_id': 'shop_1',
        'employee_id': 'em_1',
        'kind': 'paid_leave',
        'start_date': '2026-08-10',
        'end_date': '2026-08-12',
        'reason': 'Congé annuel',
        'is_paid': false,
      });
      expect(back.isPaid, isTrue);
      expect(back.hitsPayroll, isFalse);
    });

    test('un genre inconnu retombe sur le congé payé', () {
      // Se tromper dans ce sens ne coûte que de l'argent à l'employeur ; dans
      // l'autre, on ampute le salaire de quelqu'un sur une valeur illisible.
      final back = StaffAbsence.fromMap({
        'id': 'ab_2',
        'shop_id': 'shop_1',
        'employee_id': 'em_1',
        'kind': 'mise_au_vert',
        'start_date': '2026-08-10',
        'end_date': '2026-08-12',
        'reason': 'x',
      });
      expect(back.kind, AbsenceKind.paidLeave);
      expect(back.hitsPayroll, isFalse);
    });

    test('les clés stockées sont celles du CHECK SQL', () {
      expect(AbsenceKind.values.map((k) => k.key).toSet(),
          {'suspension', 'paid_leave'});
    });
  });

  group('Payslip — la retenue d\'absence sur sa propre ligne', () {
    test('elle se retranche du net', () {
      expect(Payslip.computeNet(baseSalary: 90000, absences: 9000), 81000);
    });

    test('elle se cumule avec les autres sans les écraser', () {
      expect(
        Payslip.computeNet(
          baseSalary: 90000,
          overtime: 5000,
          penalties: 10000,
          absences: 9000,
          advances: 20000,
        ),
        56000,
      );
    });

    test('la mention des jours survit à l\'aller-retour', () {
      // Le montant seul est invérifiable : ce sont les jours qui permettent de
      // refaire le calcul (mensuel ÷ 30 × jours).
      final slip = Payslip(
        id: 'pr_1',
        shopId: 'shop_1',
        employeeId: 'em_1',
        month: '2026-08',
        baseSalary: 90000,
        absencesDeducted: 9000,
        absenceDays: 3,
        netSalary: 81000,
        createdAt: DateTime(2026, 8, 31),
      );
      final back = Payslip.fromMap(slip.toMap());
      expect(back.absencesDeducted, 9000);
      expect(back.absenceDays, 3);
      expect(back.netSalary, 81000);
    });

    test('une fiche antérieure porte la ligne à zéro', () {
      final back = Payslip.fromMap({
        'id': 'pr_old',
        'shop_id': 'shop_1',
        'employee_id': 'em_1',
        'month': '2026-07',
        'base_salary': 90000,
        'net_salary': 90000,
      });
      expect(back.absencesDeducted, 0);
      expect(back.absenceDays, 0);
      expect(back.netSalary, 90000);
    });
  });
}

StaffAbsence _absence({
  required (int, int, int) start,
  required (int, int, int) end,
  AbsenceKind kind = AbsenceKind.suspension,
}) =>
    StaffAbsence(
      id: 'ab_1',
      shopId: 'shop_1',
      employeeId: 'em_1',
      employeeName: 'Awa',
      kind: kind,
      startDate: DateTime(start.$1, start.$2, start.$3),
      endDate: DateTime(end.$1, end.$2, end.$3),
      reason: 'Absence répétée sans prévenir',
      isPaid: kind == AbsenceKind.paidLeave,
      createdAt: DateTime(2026, 8, 10),
    );
