// Un salaire non encore arrêté pèse quand même sur le bénéfice.
//
// Tant qu'aucune fiche de paie n'était générée, la masse salariale du mois
// valait ZÉRO. Un restaurant à 300 000 F de salaires mensuels affichait donc,
// le 18 du mois, un bénéfice surévalué de 180 000 F — et le voyait s'effondrer
// d'un coup le jour où le gérant générait ses fiches, sans qu'aucune vente
// n'ait changé.
//
// L'estimation part des CONTRATS : somme des salaires de base des employés
// actifs, proratisée pour qui arrive en cours de mois. Elle ne génère aucune
// fiche — `generatePayslip` solde les avances, les heures supplémentaires et
// les pénalités, ce sont des écritures irréversibles qu'un affichage n'a pas à
// déclencher.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/services/staff_service.dart';
import 'package:fortress/features/restaurant/domain/entities/staff_member.dart';

StaffMember _member({
  required String id,
  int salary = 100000,
  bool active = true,
  DateTime? hired,
}) =>
    StaffMember(
      id: id,
      shopId: 's_1',
      fullName: id,
      hireDate: hired ?? DateTime(2020, 1, 1),
      createdAt: DateTime(2020, 1, 1),
      baseSalary: salary,
      isActive: active,
    );

void main() {
  group('Masse salariale estimée depuis les contrats', () {
    test('trois employés à 100 000 font 300 000', () {
      final team = [_member(id: 'a'), _member(id: 'b'), _member(id: 'c')];
      expect(StaffService.payrollEstimateFor(team, '2026-09'), 300000);
    });

    test('un employé inactif ne coûte rien', () {
      final team = [_member(id: 'a'), _member(id: 'b', active: false)];
      expect(StaffService.payrollEstimateFor(team, '2026-09'), 100000);
    });

    test('embauché EN COURS DE MOIS, il ne coûte que ses jours', () {
      // Embauché le 21 septembre : il reste 10 jours sur 30.
      final team = [_member(id: 'a', hired: DateTime(2026, 9, 21))];
      expect(StaffService.payrollEstimateFor(team, '2026-09'), 100000 * 10 ~/ 30);
    });

    test('embauché le PREMIER du mois, il coûte le mois entier', () {
      final team = [_member(id: 'a', hired: DateTime(2026, 9, 1))];
      expect(StaffService.payrollEstimateFor(team, '2026-09'), 100000);
    });

    test('embauché APRÈS le mois, il ne coûte rien', () {
      final team = [_member(id: 'a', hired: DateTime(2026, 10, 1))];
      expect(StaffService.payrollEstimateFor(team, '2026-09'), 0);
    });

    test('embauché AVANT le mois, il coûte le mois entier', () {
      final team = [_member(id: 'a', hired: DateTime(2025, 3, 15))];
      expect(StaffService.payrollEstimateFor(team, '2026-09'), 100000);
    });

    test('une équipe vide ne coûte rien', () {
      expect(StaffService.payrollEstimateFor(const [], '2026-09'), 0);
    });

    test('février proratise sur 28 jours', () {
      // Embauché le 15 février : 14 jours sur 28, soit la moitié.
      final team = [_member(id: 'a', hired: DateTime(2026, 2, 15))];
      expect(StaffService.payrollEstimateFor(team, '2026-02'), 50000);
    });
  });
}
