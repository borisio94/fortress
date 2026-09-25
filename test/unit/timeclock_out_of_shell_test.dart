import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/permisions/app_permissions.dart';
import 'package:fortress/core/permisions/user_plan.dart';
import 'package:fortress/core/services/activity_actions.dart';
import 'package:fortress/core/services/manager_gate.dart';

/// Lot « Addition et Badgeuse hors shell » (25/09/2026).
///
/// Le shell (`ShopShell`, routeur, Hive) ne se monte pas en test unitaire :
/// l'emplacement des routes est donc vérifié dans la SOURCE du routeur, comme
/// `dark_readiness_test` le fait pour les couleurs. La garde partagée
/// (`ShopAccessGuard`) est une extraction à l'identique ; elle se vérifie à
/// l'écran.
void main() {
  group('routeur', () {
    final src = File('lib/core/router/app_router.dart').readAsStringSync();
    final shell = src.indexOf('ShellRoute(');

    test('la BADGEUSE est déclarée HORS du ShellRoute, sous ShopAccessGuard',
        () {
      final route = src.indexOf("GoRoute(path: '/shop/:shopId/restaurant/pointage'");
      expect(route, greaterThan(0));
      expect(route, lessThan(shell),
          reason: 'déclarée avant le ShellRoute = route de premier niveau');
      final body = src.substring(route, src.indexOf('}),', route));
      expect(body, contains('ShopAccessGuard('),
          reason: 'hors du shell, elle perdrait sinon ses deux gardes');
      expect(body, contains('_restaurantGuard'));
    });

    test("l'ADDITION reste dans le shell, sans second décor", () {
      final route = src.indexOf(
          "GoRoute(path: '/shop/:shopId/restaurant/addition/:tableId'");
      expect(route, greaterThan(shell));
      final body = src.substring(route, src.indexOf(')),', route));
      expect(body, isNot(contains('RestoBackdrop')));
    });

    test('ShopShell passe par la même garde', () {
      final shopShell = src.substring(src.indexOf('class ShopShell'));
      expect(shopShell, contains('ShopAccessGuard('));
    });
  });

  group('ManagerGate — sortie de badgeuse', () {
    const plan = UserPlan(plan: PlanName.pro, subStatus: 'active');

    test('journalisée, dans le catalogue des actions, sur la boutique', () {
      const a = ManagerAction.exitTimeclock;
      expect(a.logAction, 'timeclock_exited');
      expect(ActivityActions.isKnown(a.logAction), isTrue);
      expect(a.targetType, 'shop');
      expect(a.title, 'Quitter la badgeuse');
    });

    test('ouverte à TOUT membre : le PIN garde la sortie, pas un droit', () {
      const serveur = AppPermissions(plan: plan, shopRole: 'user');
      expect(ManagerAction.exitTimeclock.canExecute(serveur), isTrue);
    });

    test('ne propose pas de poser le code : ce texte parle d\'argent', () {
      expect(ManagerAction.exitTimeclock.offersPinSetup, isFalse);
      for (final a in ManagerAction.values
          .where((a) => a != ManagerAction.exitTimeclock)) {
        expect(a.offersPinSetup, isTrue, reason: a.name);
        expect(a.targetType, 'order', reason: a.name);
      }
    });
  });
}
