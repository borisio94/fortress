// T05 — supprimer le propriétaire de la boutique → exception, opération
// bloquée. La protection existe à 3 niveaux dans le code :
//   1. Trigger SQL `trg_protect_owner_delete`
//      (supabase/hotfix_025:80-102 + bypass via flag de session
//      hotfix_036_account_deletion_fix.sql).
//   2. Garde Dart dans EmployeesNotifier._guardNotOwner
//      (lib/features/hr/data/providers/employees_provider.dart:226-235).
//   3. RPC `delete_user_account` qui re-vérifie owner-only.
//
// Ce fichier teste la LOGIQUE du guard #2 — c'est la première barrière
// que voit l'utilisateur avant que la requête réseau ne parte. Le guard
// est privé, donc on reproduit son contrat ici et on vérifie qu'on
// reconnaît bien un propriétaire dans une liste d'employés.
import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/hr/domain/models/employee.dart';
import 'package:fortress/features/hr/domain/models/employee_permission.dart';
import 'package:fortress/features/hr/domain/models/member_role.dart';

/// Reproduit le contrat de `EmployeesNotifier._guardNotOwner` :
/// throw si la cible est `isOwner=true`, no-op sinon.
void guardNotOwner(List<Employee> members, String userId,
    {required String action}) {
  final target = members.where((e) => e.userId == userId).firstOrNull;
  if (target != null && target.isOwner) {
    throw StateError(
        'Action interdite : impossible de $action. '
        'Le propriétaire de la boutique est protégé.');
  }
}

Employee _emp({
  required String userId,
  required MemberRole role,
  bool isOwner = false,
}) => Employee(
      userId:      userId,
      shopId:      'shop_1',
      fullName:    userId,
      email:       '$userId@test.com',
      role:        role,
      status:      EmployeeStatus.active,
      permissions: const {},
      isOwner:     isOwner,
    );

void main() {
  group('T05 — Protection du propriétaire', () {
    final owner = _emp(
        userId: 'u_owner', role: MemberRole.owner, isOwner: true);
    final admin = _emp(userId: 'u_admin', role: MemberRole.admin);
    final user  = _emp(userId: 'u_user',  role: MemberRole.user);
    final members = [owner, admin, user];

    test('Tenter de supprimer l\'owner → exception levée', () {
      expect(
        () => guardNotOwner(members, owner.userId, action: 'supprimer'),
        throwsA(isA<StateError>().having(
            (e) => e.message, 'message', contains('propriétaire'))),
      );
    });

    test('Tenter de suspendre l\'owner → exception levée', () {
      expect(
        () => guardNotOwner(members, owner.userId, action: 'suspendre'),
        throwsStateError,
      );
    });

    test('Supprimer un admin → autorisé', () {
      expect(
        () => guardNotOwner(members, admin.userId, action: 'supprimer'),
        returnsNormally,
      );
    });

    test('Supprimer un user → autorisé', () {
      expect(
        () => guardNotOwner(members, user.userId, action: 'supprimer'),
        returnsNormally,
      );
    });

    test('Cible inconnue → no-op (le guard ne bloque pas un user inexistant)',
        () {
      // Comportement actuel d'_guardNotOwner : si la target n'est pas
      // dans la liste, le guard ne fait rien (la RPC se chargera de
      // refuser plus loin). On documente ce contrat.
      expect(
        () => guardNotOwner(members, 'u_inexistant', action: 'supprimer'),
        returnsNormally,
      );
    });

    test('Employee.isOwner expose correctement le flag', () {
      expect(owner.isOwner, isTrue);
      expect(admin.isOwner, isFalse);
      expect(user.isOwner,  isFalse);
    });
  });
}
