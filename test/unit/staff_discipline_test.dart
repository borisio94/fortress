// Tenir son équipe : horaires, heures supplémentaires, casse, notation,
// primes spéciales (hotfix_165).
//
// Ce qui est en jeu ici, c'est de l'argent et la réputation de quelqu'un : un
// départ mal jugé, ce sont des heures supplémentaires payées pour rien ou une
// retenue injustifiée ; une note mal calculée, c'est un employé désigné « à
// remplacer d'urgence » alors qu'il n'a rien fait.
//
// Les services lisent Hive et ne sont pas testables en unitaire ; les RÈGLES —
// le verdict d'un service, le montant d'une heure sup, l'échéancier d'une
// casse, la note du mois, l'état d'un concours — le sont, et ce sont elles qui
// décident.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/restaurant/domain/entities/payslip.dart';
import 'package:fortress/features/restaurant/domain/entities/salary_advance.dart';
import 'package:fortress/features/restaurant/domain/entities/shift_evaluation.dart';
import 'package:fortress/features/restaurant/domain/entities/staff_contest.dart';
import 'package:fortress/features/restaurant/domain/entities/staff_member.dart';
import 'package:fortress/features/restaurant/domain/entities/staff_penalty.dart';
import 'package:fortress/features/restaurant/domain/entities/staff_rating.dart';

void main() {
  // ═══════════════════════════════════════════════════════════════════════
  //  LE VERDICT D'UN SERVICE
  // ═══════════════════════════════════════════════════════════════════════

  group('ShiftEvaluation.scheduledEndFor', () {
    test('l\'heure de fermeture tombe le jour du service', () {
      final end = ShiftEvaluation.scheduledEndFor(
          DateTime(2026, 8, 10, 9, 0), '22:00');
      expect(end, DateTime(2026, 8, 10, 22, 0));
    });

    test('un service de nuit finit le LENDEMAIN', () {
      // Entrée à 18 h dans un restaurant qui ferme à 2 h du matin. Sans le
      // report d'un jour, la fermeture serait antérieure à l'entrée et
      // l'employé serait réputé parti seize heures trop tôt.
      final end = ShiftEvaluation.scheduledEndFor(
          DateTime(2026, 8, 10, 18, 0), '02:00');
      expect(end, DateTime(2026, 8, 11, 2, 0));
    });

    test('sans horaire réglé, il n\'y a pas d\'heure de référence', () {
      expect(
          ShiftEvaluation.scheduledEndFor(DateTime(2026, 8, 10, 9, 0), null),
          isNull);
      expect(
          ShiftEvaluation.scheduledEndFor(DateTime(2026, 8, 10, 9, 0), ''),
          isNull);
    });
  });

  group('ShiftEvaluation.parseHhmm', () {
    test('accepte les formes usuelles', () {
      expect(ShiftEvaluation.parseHhmm('22:00'), (22, 0));
      expect(ShiftEvaluation.parseHhmm('9:05'), (9, 5));
      expect(ShiftEvaluation.parseHhmm('22h30'), (22, 30));
    });

    test('refuse ce qui n\'est pas une heure', () {
      expect(ShiftEvaluation.parseHhmm('25:00'), isNull);
      expect(ShiftEvaluation.parseHhmm('22:99'), isNull);
      expect(ShiftEvaluation.parseHhmm('bientôt'), isNull);
      expect(ShiftEvaluation.parseHhmm(null), isNull);
    });

    test('aller-retour avec formatHhmm', () {
      expect(ShiftEvaluation.formatHhmm(9, 5), '09:05');
      expect(ShiftEvaluation.parseHhmm(ShiftEvaluation.formatHhmm(22, 0)),
          (22, 0));
    });
  });

  group('ShiftEvaluation.of', () {
    final closing = DateTime(2026, 8, 10, 22, 0);

    test('pile à l\'heure', () {
      final v = ShiftEvaluation.of(clockOut: closing, scheduledEnd: closing);
      expect(v.ending, ShiftEnding.onTime);
      expect(v.earlyMinutes, 0);
      expect(v.overtimeMinutes, 0);
    });

    test('dans la tolérance, rien n\'est jugé', () {
      // Sans tolérance, partir trois minutes avant réclamerait une excuse et
      // rester six minutes créerait une dette : le gérant aurait vingt
      // décisions à prendre chaque soir et cesserait de s'en servir.
      for (final delta in [-14, -1, 0, 1, 14]) {
        final v = ShiftEvaluation.of(
            clockOut: closing.add(Duration(minutes: delta)),
            scheduledEnd: closing);
        expect(v.ending, ShiftEnding.onTime, reason: 'écart de $delta min');
      }
    });

    test('au-delà de la tolérance, le départ est anticipé', () {
      final v = ShiftEvaluation.of(
          clockOut: closing.subtract(const Duration(minutes: 45)),
          scheduledEnd: closing);
      expect(v.ending, ShiftEnding.early);
      expect(v.isEarly, isTrue);
      expect(v.earlyMinutes, 45);
      expect(v.overtimeMinutes, 0);
    });

    test('au-delà de la tolérance, ce sont des heures supplémentaires', () {
      final v = ShiftEvaluation.of(
          clockOut: closing.add(const Duration(hours: 2)),
          scheduledEnd: closing);
      expect(v.ending, ShiftEnding.overtime);
      expect(v.isOvertime, isTrue);
      expect(v.overtimeMinutes, 120);
      expect(v.earlyMinutes, 0);
    });

    test('la tolérance est symétrique, à la minute près', () {
      final tot = ShiftEvaluation.graceMinutes + 1;
      expect(
          ShiftEvaluation.of(
                  clockOut: closing.add(Duration(minutes: tot)),
                  scheduledEnd: closing)
              .overtimeMinutes,
          tot);
      expect(
          ShiftEvaluation.of(
                  clockOut: closing.subtract(Duration(minutes: tot)),
                  scheduledEnd: closing)
              .earlyMinutes,
          tot);
    });

    test('sans heure de référence, tout service est à l\'heure', () {
      // Un établissement qui n'a pas réglé son horaire ne doit pas voir
      // apparaître des heures supplémentaires qu'il n'a jamais promises.
      final v = ShiftEvaluation.of(
          clockOut: closing.add(const Duration(hours: 5)), scheduledEnd: null);
      expect(v.ending, ShiftEnding.onTime);
      expect(v.overtimeMinutes, 0);
    });
  });

  group('ShiftEvaluation.overtimePay', () {
    test('une heure pleine vaut le taux', () {
      expect(ShiftEvaluation.overtimePay(minutes: 60, hourlyRate: 1000), 1000);
    });

    test('les minutes sont payées au prorata', () {
      // Payer à l'heure entamée serait imprévisible : quatre soirs à dix
      // minutes coûteraient quatre heures.
      expect(ShiftEvaluation.overtimePay(minutes: 30, hourlyRate: 1000), 500);
      expect(ShiftEvaluation.overtimePay(minutes: 90, hourlyRate: 1000), 1500);
      expect(ShiftEvaluation.overtimePay(minutes: 10, hourlyRate: 1500), 250);
    });

    test('sans taux réglé, rien n\'est dû', () {
      expect(ShiftEvaluation.overtimePay(minutes: 120, hourlyRate: 0), 0);
    });

    test('jamais de montant négatif', () {
      expect(ShiftEvaluation.overtimePay(minutes: -30, hourlyRate: 1000), 0);
    });
  });

  group('TimeRecord — statuts sérialisés', () {
    test('une clé inconnue ne rend pas le pointage illisible', () {
      // Hors CHECK SQL, l'upsert serait rejeté et l'op droppée : on retombe
      // sur la valeur neutre plutôt que de perdre la ligne.
      expect(ExcuseStatusX.fromKey('n\'importe quoi'), ExcuseStatus.none);
      expect(OvertimeSettlementX.fromKey('n\'importe quoi'),
          OvertimeSettlement.pending);
    });

    test('les clés stockées sont celles du CHECK SQL', () {
      expect(ExcuseStatus.values.map((e) => e.key).toSet(),
          {'none', 'pending', 'accepted', 'refused'});
      expect(OvertimeSettlement.values.map((e) => e.key).toSet(),
          {'pending', 'paid_now', 'on_payslip'});
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  QUINZAINE
  // ═══════════════════════════════════════════════════════════════════════

  group('SalaryAdvance.fortnightCap', () {
    test('la moitié du salaire de base', () {
      expect(SalaryAdvance.fortnightCap(80000), 40000);
    });

    test('un salaire impair ne crée pas de franc fantôme', () {
      expect(SalaryAdvance.fortnightCap(75001), 37500);
    });

    test('sans salaire renseigné, aucune quinzaine', () {
      expect(SalaryAdvance.fortnightCap(0), 0);
      expect(SalaryAdvance.fortnightCap(-1), 0);
    });
  });

  group('SalaryAdvance — genre', () {
    test('une ligne écrite avant la règle est une avance', () {
      final a = SalaryAdvance.fromMap({
        'id': 'sa_1',
        'shop_id': 'shop_1',
        'employee_id': 'em_1',
        'amount': 20000,
        'advance_date': '2026-08-10',
      });
      expect(a.kind, SalaryAdvance.kindAdvance);
      expect(a.isFortnight, isFalse);
    });

    test('la quinzaine survit à l\'aller-retour', () {
      final a = SalaryAdvance(
        id: 'sa_2',
        shopId: 'shop_1',
        employeeId: 'em_1',
        amount: 40000,
        advanceDate: DateTime(2026, 8, 15),
        kind: SalaryAdvance.kindFortnight,
        createdAt: DateTime(2026, 8, 15),
      );
      expect(SalaryAdvance.fromMap(a.toMap()).isFortnight, isTrue);
    });

    test('un genre inconnu retombe sur l\'avance', () {
      final a = SalaryAdvance.fromMap({
        'id': 'sa_3',
        'shop_id': 'shop_1',
        'employee_id': 'em_1',
        'amount': 1000,
        'advance_date': '2026-08-10',
        'kind': 'prime_de_lune',
      });
      expect(a.kind, SalaryAdvance.kindAdvance);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  CASSE IMPUTÉE
  // ═══════════════════════════════════════════════════════════════════════

  group('StaffPenalty — en une fois', () {
    final p = _penalty(amount: 45000, mode: PenaltyMode.oneShot);

    test('tout est retenu sur le mois de départ', () {
      expect(p.dueFor('2026-08'), 45000);
      expect(p.monthsNeeded, 1);
    });

    test('rien avant le mois de départ', () {
      // Une casse d'août ne se retient pas sur la paie de juillet qu'on
      // régularise en retard.
      expect(p.dueFor('2026-07'), 0);
    });

    test('rien de plus une fois soldée', () {
      final settled = p.recover(45000);
      expect(settled.isSettled, isTrue);
      expect(settled.dueFor('2026-09'), 0);
      expect(settled.closedAt, isNotNull);
    });
  });

  group('StaffPenalty — étalée', () {
    final p = _penalty(
        amount: 40000, mode: PenaltyMode.installments, percentPerMonth: 25);

    test('un quart par mois, sur quatre mois', () {
      expect(p.monthlyShare, 10000);
      expect(p.monthsNeeded, 4);
      expect(p.dueFor('2026-08'), 10000);
    });

    test('la dernière échéance est plafonnée par le reste dû', () {
      // Sans ce plafond, le dernier mois retiendrait une mensualité entière
      // pour quelques francs restants.
      final almost = p.recover(35000);
      expect(almost.remaining, 5000);
      expect(almost.dueFor('2026-11'), 5000);
    });

    test('l\'arrondi ne fait pas traîner un mois de plus', () {
      // 30 % de 10 000 = 3 000 exactement ; 33 % de 10 000 = 3 300 arrondi au
      // franc supérieur, soit quatre mois et non cinq pour un reliquat de 100.
      final q = _penalty(
          amount: 10000, mode: PenaltyMode.installments, percentPerMonth: 33);
      expect(q.monthlyShare, 3300);
      expect(q.monthsNeeded, 4);
    });

    test('un pourcentage aberrant retombe sur le défaut', () {
      final q = _penalty(
          amount: 40000, mode: PenaltyMode.installments, percentPerMonth: 0);
      expect(q.monthlyShare, 10000);
    });

    test('le cumul des échéances fait exactement le montant', () {
      var current = p;
      var total = 0;
      for (var i = 0; i < 12 && !current.isSettled; i++) {
        final due = current.dueFor('2026-${(8 + i).toString().padLeft(2, '0')}');
        total += due;
        current = current.recover(due);
      }
      expect(total, 40000);
      expect(current.isSettled, isTrue);
    });
  });

  group('StaffPenalty — remboursée de sa poche', () {
    final p = _penalty(amount: 45000, mode: PenaltyMode.cashRepaid);

    test('le salaire n\'est JAMAIS touché', () {
      expect(p.hitsPayroll, isFalse);
      expect(p.monthlyShare, 0);
      expect(p.dueFor('2026-08'), 0);
      expect(p.dueFor('2026-12'), 0);
    });
  });

  group('StaffPenalty.recover', () {
    final p = _penalty(amount: 10000, mode: PenaltyMode.oneShot);

    test('ne dépasse jamais le montant dû', () {
      // Une retenue de trop ne doit pas transformer la dette en créance.
      final over = p.recover(15000);
      expect(over.amountRecovered, 10000);
      expect(over.remaining, 0);
    });

    test('un rendu partiel rouvre la pénalité', () {
      // Symétrie de la suppression d'une fiche de paie : la dette redevient
      // vivante, sinon elle serait soldée d'un mois que personne n'a payé.
      final settled = p.recover(10000);
      final reopened =
          settled.copyWith(amountRecovered: 0, clearClosedAt: true);
      expect(reopened.isSettled, isFalse);
      expect(reopened.closedAt, isNull);
      expect(reopened.dueFor('2026-08'), 10000);
    });

    test('un montant négatif est ignoré', () {
      expect(p.recover(-5000).amountRecovered, 0);
    });
  });

  group('StaffPenalty — sérialisation', () {
    test('aller-retour sans perte', () {
      final p = _penalty(
          amount: 40000,
          mode: PenaltyMode.installments,
          percentPerMonth: 25).recover(10000);
      final back = StaffPenalty.fromMap(p.toMap());
      expect(back.amount, 40000);
      expect(back.mode, PenaltyMode.installments);
      expect(back.percentPerMonth, 25);
      expect(back.amountRecovered, 10000);
      expect(back.startMonth, '2026-08');
      expect(back.reason, 'A fait tomber le blender');
    });

    test('un mode inconnu retombe sur la retenue en une fois', () {
      // Le mode le plus courant, et celui qui ne fait pas disparaître la dette.
      final back = StaffPenalty.fromMap({
        'id': 'pe_1',
        'shop_id': 'shop_1',
        'employee_id': 'em_1',
        'item_label': 'Blender',
        'amount': 1000,
        'mode': 'offert_par_la_maison',
        'start_month': '2026-08',
        'reason': 'x',
        'incident_date': '2026-08-10',
      });
      expect(back.mode, PenaltyMode.oneShot);
    });

    test('sans mois de départ, la casse se rattache à son incident', () {
      final back = StaffPenalty.fromMap({
        'id': 'pe_2',
        'shop_id': 'shop_1',
        'employee_id': 'em_1',
        'item_label': 'Verre',
        'amount': 500,
        'reason': 'x',
        'incident_date': '2026-08-10',
      });
      expect(back.startMonth, '2026-08');
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  NOTATION
  // ═══════════════════════════════════════════════════════════════════════

  group('StaffScore', () {
    test('sans événement, la note est au maximum', () {
      const s = StaffScore.clean();
      expect(s.score, 10);
      expect(s.surplus, 0);
      expect(s.label, '10');
      expect(s.gauge, 1.0);
      expect(s.needsReplacement, isFalse);
    });

    test('les points retirés font descendre la note', () {
      const s = StaffScore(-3);
      expect(s.score, 7);
      expect(s.surplus, 0);
      expect(s.label, '7');
      expect(s.gauge, closeTo(0.7, 0.001));
    });

    test('les bonus remontent une note entamée', () {
      // « Si tu avais déjà eu des points retranchés, il remonte ta note. »
      const s = StaffScore(-3 + 2);
      expect(s.score, 9);
      expect(s.surplus, 0);
    });

    test('au-delà de 10, le surplus s\'affiche en plus', () {
      // « Si tu étais à 10, on aura un + suivi du nombre de points reçus. »
      const s = StaffScore(3);
      expect(s.score, 10);
      expect(s.surplus, 3);
      expect(s.label, '10 +3');
      expect(s.gauge, 1.0);
    });

    test('la note ne devient jamais négative', () {
      const s = StaffScore(-25);
      expect(s.score, 0);
      expect(s.gauge, 0.0);
      expect(s.needsReplacement, isTrue);
    });

    test('en deçà de 5, l\'employé est signalé à remplacer', () {
      expect(const StaffScore(-6).score, 4);
      expect(const StaffScore(-6).needsReplacement, isTrue);
      // Exactement 5 n'est PAS « en deçà de 5 ».
      expect(const StaffScore(-5).score, 5);
      expect(const StaffScore(-5).needsReplacement, isFalse);
    });

    test('le classement met le meilleur en tête', () {
      final list = [
        const StaffScore(-4),
        const StaffScore(2),
        const StaffScore(0),
      ]..sort(StaffScore.compare);
      expect(list.map((s) => s.raw).toList(), [12, 10, 6]);
    });

    test('le surplus départage deux employés à 10', () {
      // Sans lui, celui qui a été félicité trois fois serait à égalité avec
      // celui dont on n'a jamais rien eu à dire.
      expect(StaffScore.compare(const StaffScore(3), const StaffScore(0)),
          lessThan(0));
    });
  });

  group('StaffRating — sérialisation', () {
    test('aller-retour sans perte', () {
      final r = StaffRating(
        id: 'ra_1',
        shopId: 'shop_1',
        employeeId: 'em_1',
        employeeName: 'Awa',
        points: -2,
        reason: 'Plainte table 4, jugée fondée',
        source: StaffRating.sourceComplaint,
        month: '2026-08',
        createdAt: DateTime(2026, 8, 10, 21, 30),
      );
      final back = StaffRating.fromMap(r.toMap());
      expect(back.points, -2);
      expect(back.isPenalty, isTrue);
      expect(back.reason, 'Plainte table 4, jugée fondée');
      expect(back.source, StaffRating.sourceComplaint);
      expect(back.month, '2026-08');
    });

    test('une source inconnue ne rend pas l\'événement illisible', () {
      final back = StaffRating.fromMap({
        'id': 'ra_2',
        'shop_id': 'shop_1',
        'employee_id': 'em_1',
        'points': 1,
        'reason': 'x',
        'source': 'ragot',
        'month': '2026-08',
      });
      expect(back.source, StaffRating.sourceOther);
    });

    test('sans mois, l\'événement se rattache à sa date', () {
      final back = StaffRating.fromMap({
        'id': 'ra_3',
        'shop_id': 'shop_1',
        'employee_id': 'em_1',
        'points': 1,
        'reason': 'x',
        'created_at': DateTime(2026, 8, 10).toUtc().toIso8601String(),
      });
      expect(back.month, '2026-08');
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  PRIMES SPÉCIALES
  // ═══════════════════════════════════════════════════════════════════════

  group('StaffContest.stateAt', () {
    final c = _contest();

    test('avant le début : à venir', () {
      expect(c.stateAt(DateTime(2026, 8, 1)), ContestState.upcoming);
    });

    test('pendant la période : en cours', () {
      expect(c.stateAt(DateTime(2026, 8, 10)), ContestState.running);
    });

    test('la journée de fin compte ENTIÈREMENT', () {
      // Un concours annoncé « jusqu'au 15 » court jusqu'au 15 au soir. Sans
      // ça, la dernière journée promise à l'équipe ne compterait pas.
      expect(c.stateAt(DateTime(2026, 8, 15, 23, 0)), ContestState.running);
      expect(c.stateAt(DateTime(2026, 8, 16, 0, 1)), ContestState.toAward);
    });

    test('vainqueur désigné : à verser', () {
      final awarded = c.copyWith(
          winnerId: 'em_1',
          winnerName: 'Awa',
          awardedAt: DateTime(2026, 8, 16));
      expect(awarded.hasWinner, isTrue);
      expect(awarded.stateAt(DateTime(2026, 8, 16)), ContestState.awarded);
    });

    test('prime versée : terminé', () {
      final paid = c.copyWith(
          winnerId: 'em_1',
          winnerName: 'Awa',
          paidAt: DateTime(2026, 8, 17));
      expect(paid.isPaid, isTrue);
      expect(paid.stateAt(DateTime(2026, 8, 17)), ContestState.paid);
    });

    test('retirer le vainqueur efface AUSSI le versement', () {
      // La prime a été remise à quelqu'un qui n'aurait pas dû la recevoir :
      // garder la trace du paiement fausserait la caisse.
      final paid = c.copyWith(
          winnerId: 'em_1', winnerName: 'Awa', paidAt: DateTime(2026, 8, 17));
      final cleared = paid.copyWith(clearWinner: true);
      expect(cleared.hasWinner, isFalse);
      expect(cleared.isPaid, isFalse);
      expect(cleared.stateAt(DateTime(2026, 8, 17)), ContestState.toAward);
    });
  });

  group('StaffContest.daysLeftAt', () {
    final c = _contest();

    test('compte les jours restants', () {
      expect(c.daysLeftAt(DateTime(2026, 8, 10)), 5);
      expect(c.daysLeftAt(DateTime(2026, 8, 15, 8, 0)), 0);
    });

    test('jamais négatif une fois terminé', () {
      expect(c.daysLeftAt(DateTime(2026, 9, 1)), 0);
    });
  });

  group('StaffContest — sérialisation', () {
    test('aller-retour sans perte', () {
      final back = StaffContest.fromMap(_contest().toMap());
      expect(back.title, 'Meilleur vendeur de chawarmas');
      expect(back.prize, 20000);
      expect(back.startDate, DateTime(2026, 8, 5));
      expect(back.endDate, DateTime(2026, 8, 15));
      expect(back.paidCash, isTrue);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  PAIE — ce que les nouvelles lignes font au net
  // ═══════════════════════════════════════════════════════════════════════

  group('Payslip.computeNet — heures supplémentaires et casse', () {
    test('les heures supplémentaires s\'ajoutent', () {
      expect(
        Payslip.computeNet(baseSalary: 80000, overtime: 6000),
        86000,
      );
    });

    test('la casse se retranche', () {
      expect(
        Payslip.computeNet(baseSalary: 80000, penalties: 10000),
        70000,
      );
    });

    test('tout se combine dans le bon sens', () {
      expect(
        Payslip.computeNet(
          baseSalary: 80000,
          bonuses: 5000,
          overtime: 6000,
          deductions: 2000,
          penalties: 10000,
          advances: 20000,
        ),
        59000,
      );
    });

    test('le net ne devient jamais négatif, même avec une grosse casse', () {
      // On ne réclame pas d'argent à l'employé en fin de mois : le reliquat
      // reste dû via la pénalité non soldée.
      expect(
        Payslip.computeNet(baseSalary: 50000, penalties: 200000),
        0,
      );
    });

    test('une fiche sans les nouvelles lignes calcule comme avant', () {
      expect(
        Payslip.computeNet(baseSalary: 80000, bonuses: 10000, advances: 20000),
        70000,
      );
    });
  });

  group('Payslip — mentions stockées', () {
    test('les heures supplémentaires gardent leur mention', () {
      // Le montant seul est invérifiable : c'est le nombre d'heures à côté qui
      // permet à l'employé de refaire le calcul.
      final slip = Payslip(
        id: 'pr_1',
        shopId: 'shop_1',
        employeeId: 'em_1',
        month: '2026-08',
        baseSalary: 80000,
        overtimeAmount: 6000,
        overtimeMinutes: 360,
        penaltiesDeducted: 10000,
        netSalary: 76000,
        createdAt: DateTime(2026, 8, 31),
      );
      final back = Payslip.fromMap(slip.toMap());
      expect(back.overtimeAmount, 6000);
      expect(back.overtimeMinutes, 360);
      expect(back.penaltiesDeducted, 10000);
      expect(back.netSalary, 76000);
    });

    test('une fiche v1 relue porte ces lignes à zéro', () {
      final back = Payslip.fromMap({
        'id': 'pr_old',
        'shop_id': 'shop_1',
        'employee_id': 'em_1',
        'month': '2026-07',
        'base_salary': 80000,
        'net_salary': 80000,
      });
      expect(back.overtimeAmount, 0);
      expect(back.penaltiesDeducted, 0);
      expect(back.netSalary, 80000);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  MIGRATION DE SCHÉMA — le piège de la step mal indexée
  // ═══════════════════════════════════════════════════════════════════════

  group('StaffMember — migration v1 → v3', () {
    test('une fiche v1 est réputée rattachée à un compte', () {
      // C'était la seule façon d'en créer une avant hotfix_162.
      final m = StaffMember.fromMap({
        'id': 'em_1',
        'shop_id': 'shop_1',
        'full_name': 'Awa',
        'hire_date': '2026-01-01',
      });
      expect(m.hasAppAccess, isTrue);
    });

    test('une fiche v2 SANS compte le reste après migration', () {
      // RÉGRESSION : la step v1→v2 était indexée sur 2 au lieu de 1. Elle ne
      // s'exécutait jamais tant que la cible valait 2 — mais serait devenue
      // active au passage à v3, remettant `has_app_access` à vrai sur tout le
      // personnel sans compte, c'est-à-dire en effaçant exactement ce que la
      // v2 était venue introduire.
      final m = StaffMember.fromMap({
        'schema_version': 2,
        'id': 'em_2',
        'shop_id': 'shop_1',
        'full_name': 'Moussa le veilleur',
        'hire_date': '2026-01-01',
        'has_app_access': false,
      });
      expect(m.hasAppAccess, isFalse);
    });

    test('l\'horaire particulier survit à l\'aller-retour', () {
      final m = StaffMember(
        id: 'em_3',
        shopId: 'shop_1',
        fullName: 'Le boulanger',
        hireDate: DateTime(2026, 1, 1),
        createdAt: DateTime(2026, 1, 1),
        closingTime: '11:00',
      );
      expect(StaffMember.fromMap(m.toMap()).closingTime, '11:00');
    });

    test('sans horaire particulier, l\'employé suit la boutique', () {
      final m = StaffMember(
        id: 'em_4',
        shopId: 'shop_1',
        fullName: 'Awa',
        hireDate: DateTime(2026, 1, 1),
        createdAt: DateTime(2026, 1, 1),
        closingTime: '11:00',
      );
      final back = m.copyWith(clearClosingTime: true);
      expect(back.closingTime, isNull);
      expect(StaffMember.fromMap(back.toMap()).closingTime, isNull);
    });
  });
}

StaffPenalty _penalty({
  required int amount,
  required PenaltyMode mode,
  int percentPerMonth = 25,
}) =>
    StaffPenalty(
      id: 'pe_1',
      shopId: 'shop_1',
      employeeId: 'em_1',
      employeeName: 'Awa',
      itemLabel: 'Blender',
      amount: amount,
      mode: mode,
      percentPerMonth: percentPerMonth,
      startMonth: '2026-08',
      reason: 'A fait tomber le blender',
      incidentDate: DateTime(2026, 8, 10),
      createdAt: DateTime(2026, 8, 10),
    );

StaffContest _contest() => StaffContest(
      id: 'co_1',
      shopId: 'shop_1',
      title: 'Meilleur vendeur de chawarmas',
      conditions: 'Le plus de chawarmas servis, sans plainte client.',
      prize: 20000,
      startDate: DateTime(2026, 8, 5),
      endDate: DateTime(2026, 8, 15),
      createdAt: DateTime(2026, 8, 1),
    );
