// T03 et T04 — limite d'administrateurs (propriétaire inclus = max 3).
//
// La règle est enforcée à 3 endroits dans le code :
//   1. Trigger SQL `trg_enforce_max_admins`
//      (supabase/hotfix_024 + hotfix_037).
//   2. Garde Dart côté form (lib/features/hr/presentation/pages/
//      employee_form_sheet.dart::_submit) avant l'appel RPC.
//   3. RPC `create_employee` v2 (hotfix_038) qui rejoue le trigger.
//
// Ce fichier teste la LOGIQUE de comptage qui sert à l'étape 2 (la garde
// Dart) — c'est la même logique attendue côté SQL. On test sur une liste
// d'`Employee` simulée.
import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/hr/domain/models/employee.dart';
import 'package:fortress/features/hr/domain/models/employee_permission.dart';
import 'package:fortress/features/hr/domain/models/member_role.dart';

const int kMaxAdmins = 3; // owner inclus

/// Compte les admins+owner actifs dans une liste, en excluant éventuellement
/// l'employé courant (cas d'une self-update qui ne devrait pas se compter
/// deux fois). Mirroir exact de la logique du trigger SQL et de la garde
/// Dart dans employee_form_sheet.dart::_submit.
int countActiveAdmins(List<Employee> members, {String? excludeUserId}) =>
    members.where((e) =>
        e.userId != excludeUserId &&
        (e.isOwner || e.role == MemberRole.admin) &&
        e.status == EmployeeStatus.active).length;

/// Décide si un nouvel admin peut être désigné (création OU promotion).
/// Retourne `false` si la limite serait dépassée.
bool canDesignateNewAdmin(List<Employee> members, {String? excludeUserId}) =>
    countActiveAdmins(members, excludeUserId: excludeUserId) < kMaxAdmins;

Employee _emp({
  required String userId,
  required MemberRole role,
  bool   isOwner = false,
  EmployeeStatus status = EmployeeStatus.active,
}) => Employee(
      userId:      userId,
      shopId:      'shop_1',
      fullName:    userId,
      email:       '$userId@test.com',
      role:        role,
      status:      status,
      permissions: const {},
      isOwner:     isOwner,
    );

void main() {
  group('Comptage admins (mirroir du trigger SQL)', () {
    test('aucun admin → count = 0', () {
      expect(countActiveAdmins([]), 0);
    });

    test('owner uniquement → count = 1', () {
      final owner = _emp(
          userId: 'u_owner', role: MemberRole.owner, isOwner: true);
      expect(countActiveAdmins([owner]), 1);
    });

    test('admin suspendu n\'est pas compté', () {
      final owner = _emp(
          userId: 'u_owner', role: MemberRole.owner, isOwner: true);
      final suspended = _emp(
          userId: 'u_susp', role: MemberRole.admin,
          status: EmployeeStatus.suspended);
      expect(countActiveAdmins([owner, suspended]), 1);
    });

    test('admin archivé n\'est pas compté', () {
      final owner = _emp(
          userId: 'u_owner', role: MemberRole.owner, isOwner: true);
      final archived = _emp(
          userId: 'u_arch', role: MemberRole.admin,
          status: EmployeeStatus.archived);
      expect(countActiveAdmins([owner, archived]), 1);
    });
  });

  group('Limite des 3 administrateurs (owner inclus)', () {
    test('T03 — invitation 1er admin (1 owner + 0 admin) → autorisée', () {
      final members = [
        _emp(userId: 'u_owner', role: MemberRole.owner, isOwner: true),
      ];
      expect(canDesignateNewAdmin(members), isTrue,
          reason: '1 < 3, on peut promouvoir un 2e administrateur');
    });

    test('T03 — invitation 2e admin (1 owner + 1 admin) → autorisée', () {
      final members = [
        _emp(userId: 'u_owner', role: MemberRole.owner, isOwner: true),
        _emp(userId: 'u_admin1', role: MemberRole.admin),
      ];
      expect(canDesignateNewAdmin(members), isTrue,
          reason: '2 < 3, on peut promouvoir un 3e administrateur');
    });

    test('T04 — invitation 3e admin (1 owner + 2 admins) → REFUSÉE', () {
      final members = [
        _emp(userId: 'u_owner',  role: MemberRole.owner, isOwner: true),
        _emp(userId: 'u_admin1', role: MemberRole.admin),
        _emp(userId: 'u_admin2', role: MemberRole.admin),
      ];
      expect(canDesignateNewAdmin(members), isFalse,
          reason: '3 >= 3, la limite est atteinte (owner inclus)');
    });

    test('T04 — invitation 4e admin → REFUSÉE (encore plus loin de la limite)',
        () {
      final members = [
        _emp(userId: 'u_owner',  role: MemberRole.owner, isOwner: true),
        _emp(userId: 'u_admin1', role: MemberRole.admin),
        _emp(userId: 'u_admin2', role: MemberRole.admin),
        _emp(userId: 'u_admin3', role: MemberRole.admin), // déjà au-dessus
      ];
      expect(canDesignateNewAdmin(members), isFalse,
          reason: 'au-delà de la limite : tout nouvel admin est refusé');
    });

    test('Auto-update d\'un admin existant (qui reste admin) → pas comptée 2 fois',
        () {
      // Cas : on édite l'admin u_admin1 sans changer son rôle. Le trigger
      // SQL doit l'exclure du count via NOT (shop_id=OLD.shop_id AND user_id=OLD.user_id).
      final members = [
        _emp(userId: 'u_owner',  role: MemberRole.owner, isOwner: true),
        _emp(userId: 'u_admin1', role: MemberRole.admin),
        _emp(userId: 'u_admin2', role: MemberRole.admin),
      ];
      // On exclut u_admin1 (le sujet de l'update).
      expect(canDesignateNewAdmin(members, excludeUserId: 'u_admin1'), isTrue,
          reason: '2 (owner+admin2) < 3 quand on s\'exclut soi-même');
    });
  });
}
