// Tests du personnel : pointage, avances et paie (Lot D).
//
// Ce qui est en jeu : le net d'une fiche de paie est ce qu'un employé reçoit à
// la fin du mois. Une avance oubliée, c'est la boutique qui paie deux fois ;
// une avance comptée deux fois, c'est l'employé qui perd un mois de salaire.
//
// `StaffService` lit Hive et n'est pas testable en unitaire ; les règles — net,
// durée, hachage du code de pointage, clés de mois — le sont.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/services/staff_service.dart';
import 'package:fortress/features/restaurant/domain/entities/payslip.dart';
import 'package:fortress/features/restaurant/domain/entities/salary_advance.dart';
import 'package:fortress/features/restaurant/domain/entities/staff_member.dart';
import 'package:fortress/features/restaurant/domain/entities/time_record.dart';

/// Modes acceptés par le CHECK SQL de `time_records.method` (hotfix_148).
const _kSqlMethods = {'pin', 'qr_code', 'manual'};

void main() {
  group('Payslip.computeNet', () {
    test('base + primes − retenues − avances', () {
      expect(
        Payslip.computeNet(
            baseSalary: 80000, bonuses: 10000, deductions: 5000, advances: 20000),
        65000,
      );
    });

    test('sans rien, le net est le salaire de base', () {
      expect(Payslip.computeNet(baseSalary: 80000), 80000);
    });

    test('le net ne devient jamais négatif', () {
      // Avances supérieures au salaire : on ne réclame pas d'argent à
      // l'employé en fin de mois. Le reliquat reste dû via les avances non
      // soldées ; un net négatif sur une fiche de paie n'a aucun sens.
      expect(
        Payslip.computeNet(baseSalary: 50000, advances: 80000),
        0,
      );
    });

    test('les avances pèsent autant que les retenues', () {
      // Deux chemins différents, un même effet sur le net : c'est ce qui
      // permet de les afficher séparément sans fausser le total.
      final a = Payslip.computeNet(baseSalary: 100000, advances: 15000);
      final b = Payslip.computeNet(baseSalary: 100000, deductions: 15000);
      expect(a, b);
    });
  });

  group('Payslip — sérialisation', () {
    final slip = Payslip(
      id: 'pr_1',
      shopId: 'shop_1',
      employeeId: 'em_1',
      employeeName: 'Awa',
      month: '2026-07',
      baseSalary: 80000,
      bonuses: 10000,
      deductions: 5000,
      advancesDeducted: 20000,
      minutesWorked: 9600,
      netSalary: 65000,
      createdAt: DateTime(2026, 7, 31),
    );

    test('aller-retour sans perte', () {
      final back = Payslip.fromMap(slip.toMap());
      expect(back.month, '2026-07');
      expect(back.baseSalary, 80000);
      expect(back.advancesDeducted, 20000);
      expect(back.minutesWorked, 9600);
      expect(back.netSalary, 65000);
      expect(back.isPaid, isFalse);
    });

    test('le net STOCKÉ fait foi', () {
      // Une fiche remise à l'employé est un document : si le salaire de base
      // change en septembre, la fiche de juillet doit continuer d'afficher ce
      // qui a été versé en juillet.
      final raw = slip.toMap()..['net_salary'] = 61234;
      expect(Payslip.fromMap(raw).netSalary, 61234);
    });

    test('un net absent est reconstruit', () {
      final raw = slip.toMap()..remove('net_salary');
      expect(Payslip.fromMap(raw).netSalary, 65000);
    });
  });

  group('TimeRecord — durées', () {
    test('les minutes entre deux horodatages', () {
      expect(
        TimeRecord.minutesBetween(
            DateTime(2026, 7, 28, 8), DateTime(2026, 7, 28, 15, 30)),
        450,
      );
    });

    test('une sortie antérieure à l\'entrée ne crée pas de durée négative', () {
      // Horloge d'appareil mal réglée : mieux vaut zéro qu'un total d'heures
      // du mois amputé.
      expect(
        TimeRecord.minutesBetween(
            DateTime(2026, 7, 28, 15), DateTime(2026, 7, 28, 8)),
        0,
      );
    });

    test('un service de nuit compte ses heures', () {
      // 22h → 2h du matin le lendemain : 4 heures, pas zéro.
      expect(
        TimeRecord.minutesBetween(
            DateTime(2026, 7, 28, 22), DateTime(2026, 7, 29, 2)),
        240,
      );
    });

    test('la durée FIGÉE prime sur le calcul', () {
      // Un pointage corrigé à la main garde la durée validée par le gérant,
      // pas celle que redonneraient deux horodatages approximatifs.
      final r = TimeRecord(
        id: 'tc_1',
        shopId: 'shop_1',
        employeeId: 'em_1',
        clockIn: DateTime(2026, 7, 28, 8),
        clockOut: DateTime(2026, 7, 28, 18),
        durationMinutes: 480, // 8h validées au lieu de 10h d'amplitude
        createdAt: DateTime(2026, 7, 28),
      );
      expect(r.worked.inMinutes, 480);
    });

    test('un service en cours reste ouvert', () {
      final r = TimeRecord(
        id: 'tc_1',
        shopId: 'shop_1',
        employeeId: 'em_1',
        clockIn: DateTime.now().subtract(const Duration(hours: 2)),
        createdAt: DateTime.now(),
      );
      expect(r.isOpen, isTrue);
      expect(r.worked.inMinutes, greaterThanOrEqualTo(119));
    });

    test('formatMinutes reste lisible', () {
      expect(TimeRecord.formatMinutes(45), '45 min');
      expect(TimeRecord.formatMinutes(60), '1h');
      expect(TimeRecord.formatMinutes(450), '7h30');
      expect(TimeRecord.formatMinutes(605), '10h05');
    });

    test('les modes émis existent côté SQL', () {
      for (final m in _kSqlMethods) {
        final raw = TimeRecord(
          id: 'tc_1',
          shopId: 'shop_1',
          employeeId: 'em_1',
          method: m,
          createdAt: DateTime(2026, 7, 28),
        ).toMap();
        expect(TimeRecord.fromMap(raw).method, m);
      }
    });

    test('un mode inconnu retombe sur « pin »', () {
      // Hors CHECK, l'upsert serait rejeté et l'op droppée après dix essais.
      final raw = TimeRecord(
        id: 'tc_1',
        shopId: 'shop_1',
        employeeId: 'em_1',
        createdAt: DateTime(2026, 7, 28),
      ).toMap()
        ..['method'] = 'empreinte';
      expect(TimeRecord.fromMap(raw).method, 'pin');
    });
  });

  group('Code de pointage', () {
    test('quatre chiffres, ni plus ni moins', () {
      expect(StaffService.isValidPin('1234'), isTrue);
      expect(StaffService.isValidPin('123'), isFalse);
      expect(StaffService.isValidPin('12345'), isFalse);
      expect(StaffService.isValidPin('12a4'), isFalse);
      expect(StaffService.isValidPin(''), isFalse);
    });

    test('le même code sous deux sels donne deux hachages', () {
      // C'est tout l'intérêt du sel : deux employés avec le code 1234 ne
      // partagent aucune valeur en base, et on ne peut pas déduire l'un de
      // l'autre.
      final a = StaffService.hashPin('1234', 'sel-a');
      final b = StaffService.hashPin('1234', 'sel-b');
      expect(a, isNot(b));
    });

    test('le hachage est stable et ne contient pas le code', () {
      final h = StaffService.hashPin('1234', 'sel-a');
      expect(StaffService.hashPin('1234', 'sel-a'), h);
      expect(h.contains('1234'), isFalse);
      expect(h.length, 64); // SHA-256 en hexadécimal
    });

    test('un code différent change le hachage', () {
      expect(StaffService.hashPin('1234', 'sel'),
          isNot(StaffService.hashPin('1235', 'sel')));
    });
  });

  group('StaffMember — sérialisation', () {
    final m = StaffMember(
      id: 'em_1',
      shopId: 'shop_1',
      fullName: 'Awa Ndiaye',
      role: 'Serveuse',
      baseSalary: 80000,
      hireDate: DateTime(2026, 3, 1),
      phone: '690000000',
      station: 'Salle',
      pinHash: 'abc',
      pinSalt: 'sel',
      createdAt: DateTime(2026, 3, 1),
    );

    test('aller-retour sans perte', () {
      final back = StaffMember.fromMap(m.toMap());
      expect(back.fullName, 'Awa Ndiaye');
      expect(back.role, 'Serveuse');
      expect(back.baseSalary, 80000);
      expect(back.station, 'Salle');
      expect(back.isActive, isTrue);
      expect(back.hasPin, isTrue);
    });

    test('clearPin retire vraiment le code', () {
      // `copyWith(pinHash: null)` serait un no-op silencieux et l'employé
      // continuerait de pouvoir badger après qu'on lui a retiré son code.
      expect(m.copyWith(pinHash: null).hasPin, isTrue);
      expect(m.copyWith(clearPin: true).hasPin, isFalse);
    });

    test('sans hachage ET sans sel, pas de badgeage', () {
      expect(m.copyWith().hasPin, isTrue);
      final raw = m.toMap()..['pin_salt'] = '';
      expect(StaffMember.fromMap(raw).hasPin, isFalse);
    });
  });

  group('Sorties d\'espèces du personnel', () {
    test('une avance est réputée versée en espèces par défaut', () {
      // Cas dominant au restaurant : le gérant prend l'argent dans le tiroir.
      // Sans ce défaut, la clôture continuerait d'annoncer un manquant.
      final a = SalaryAdvance(
        id: 'sa_1',
        shopId: 'shop_1',
        employeeId: 'em_1',
        amount: 20000,
        advanceDate: DateTime(2026, 7, 15),
        createdAt: DateTime(2026, 7, 15),
      );
      expect(a.isCash, isTrue);
      expect(SalaryAdvance.fromMap(a.toMap()).isCash, isTrue);
    });

    test('une avance par virement ne touche pas le tiroir', () {
      final a = SalaryAdvance(
        id: 'sa_1',
        shopId: 'shop_1',
        employeeId: 'em_1',
        amount: 20000,
        advanceDate: DateTime(2026, 7, 15),
        isCash: false,
        createdAt: DateTime(2026, 7, 15),
      );
      expect(SalaryAdvance.fromMap(a.toMap()).isCash, isFalse);
    });

    test('un salaire est réputé payé en espèces, et seulement une fois payé', () {
      final slip = Payslip(
        id: 'pr_1',
        shopId: 'shop_1',
        employeeId: 'em_1',
        month: '2026-07',
        netSalary: 65000,
        createdAt: DateTime(2026, 7, 31),
      );
      expect(slip.paidCash, isTrue);
      // Tant que la fiche n'est pas payée, rien ne sort du tiroir.
      expect(slip.isPaid, isFalse);
      final paid = slip.copyWith(paidAt: DateTime(2026, 8, 2));
      expect(Payslip.fromMap(paid.toMap()).isPaid, isTrue);
      expect(Payslip.fromMap(paid.toMap()).paidCash, isTrue);
    });
  });

  group('SalaryAdvance — rattachement au mois de paie', () {
    test('la clé de mois est au format de payroll.month', () {
      expect(SalaryAdvance.monthKey(DateTime(2026, 7, 28)), '2026-07');
      expect(SalaryAdvance.monthKey(DateTime(2026, 12, 1)), '2026-12');
    });

    test('une avance sans mois est rattachée au mois de son versement', () {
      // Sinon elle serait invisible au moment de préparer la paie, et
      // l'employé serait payé deux fois.
      final a = SalaryAdvance(
        id: 'sa_1',
        shopId: 'shop_1',
        employeeId: 'em_1',
        amount: 20000,
        advanceDate: DateTime(2026, 7, 15),
        createdAt: DateTime(2026, 7, 15),
      );
      final raw = a.toMap()..remove('deducted_from_month');
      expect(SalaryAdvance.fromMap(raw).deductedFromMonth, '2026-07');
    });

    test('un mois de retenue explicite est conservé', () {
      // Une avance de fin de mois se retient souvent sur le mois suivant.
      final a = SalaryAdvance(
        id: 'sa_1',
        shopId: 'shop_1',
        employeeId: 'em_1',
        amount: 20000,
        advanceDate: DateTime(2026, 7, 30),
        deductedFromMonth: '2026-08',
        createdAt: DateTime(2026, 7, 30),
      );
      expect(SalaryAdvance.fromMap(a.toMap()).deductedFromMonth, '2026-08');
    });

    test('une avance retenue reste marquée comme telle', () {
      final a = SalaryAdvance(
        id: 'sa_1',
        shopId: 'shop_1',
        employeeId: 'em_1',
        amount: 20000,
        advanceDate: DateTime(2026, 7, 15),
        isDeducted: true,
        createdAt: DateTime(2026, 7, 15),
      );
      expect(SalaryAdvance.fromMap(a.toMap()).isDeducted, isTrue);
    });
  });
}
