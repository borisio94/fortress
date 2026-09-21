// Le stock quitte les finances, et prend ses propres droits.
//
// Le hub « Finances » portait six onglets, dont trois n'étaient pas
// financiers : Ingrédients, Fournitures, Activités. Le premier — un écran de
// réserve — s'ouvrait par défaut, si bien qu'un clic sur « Finances »
// atterrissait sur l'inventaire de l'huile.
//
// Ingrédients et Fournitures sont sortis vers un écran STOCK, avec sa propre
// entrée de menu. Ce n'est pas qu'un rangement : la séparation n'a de sens que
// si quelqu'un peut COMPTER LA RÉSERVE SANS LIRE LES MARGES. Les deux entrées
// portent donc des droits différents — `canManageStock` d'un côté,
// `isShopAdmin` de l'autre.
//
// Une régression ici est silencieuse : elle ne casse rien, elle rend juste le
// stock invisible, ou les marges lisibles par tout le monde.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:fortress/core/i18n/app_localizations.dart';
import 'package:fortress/core/permisions/app_permissions.dart';
import 'package:fortress/core/permisions/user_plan.dart';
import 'package:fortress/features/hr/domain/models/employee_permission.dart';
import 'package:fortress/shared/navigation/shell_nav_items.dart';

void main() {
  const plan = UserPlan(plan: PlanName.pro, subStatus: 'active');

  const gerant = AppPermissions(plan: plan, shopRole: 'admin');
  const serveur = AppPermissions(plan: plan, shopRole: 'user');

  /// Un employé à qui le gérant a accordé « Gérer le stock », et rien de plus.
  const magasinier = AppPermissions(
    plan: plan,
    shopRole: 'user',
    customPermissions: MemberPermissions(
      grants: {EmployeePermission.inventoryStock},
      denies: {},
    ),
  );

  ShellNavItem itemAt(String route) => kShellNavItems.firstWhere(
      (i) => i.route('shop_1') == route,
      orElse: () => throw StateError('route absente du menu : $route'));

  const kStock = '/shop/shop_1/restaurant/stock';
  const kFinances = '/shop/shop_1/restaurant/finances';

  group('L\'entrée Stock existe et reste au restaurant', () {
    test('elle est au menu, sous le libellé « Stock »', () {
      const l = AppLocalizations(Locale('fr'));
      expect(itemAt(kStock).label(l), 'Stock');
    });

    test('elle est réservée aux secteurs de restauration', () {
      final stock = itemAt(kStock);
      expect(stock.matchesSector('restaurant'), isTrue);
      expect(stock.matchesSector('fastfood'), isTrue);
      expect(stock.matchesSector('ecommerce'), isFalse,
          reason: 'l\'e-commerce a déjà sa propre entrée « Stock »');
      expect(stock.matchesSector('retail'), isFalse);
    });

    test('elle se place APRÈS le Menu et AVANT les Finances', () {
      // L'ordre du menu suit le parcours d'usage : on compose sa carte, on
      // gère ce qu'elle consomme, puis on regarde ce que ça coûte.
      final routes = kShellNavItems
          .where((i) => i.matchesSector('restaurant'))
          .map((i) => i.route('shop_1'))
          .toList();
      final menu = routes.indexOf('/shop/shop_1/inventaire');
      final stock = routes.indexOf(kStock);
      final finances = routes.indexOf(kFinances);
      expect(menu, greaterThanOrEqualTo(0));
      expect(stock, greaterThan(menu));
      expect(finances, greaterThan(stock));
    });
  });

  group('Compter la réserve sans lire les marges', () {
    test('un magasinier voit Stock', () {
      expect(itemAt(kStock).visibleIf(magasinier), isTrue);
    });

    test('et ne voit PAS Finances', () {
      // C'est tout l'objet de la séparation. Sans ça, elle serait cosmétique.
      expect(itemAt(kFinances).visibleIf(magasinier), isFalse);
    });

    test('un gérant voit les deux — nul n\'y perd', () {
      expect(itemAt(kStock).visibleIf(gerant), isTrue);
      expect(itemAt(kFinances).visibleIf(gerant), isTrue);
    });

    test('un serveur ne voit ni l\'un ni l\'autre', () {
      expect(itemAt(kStock).visibleIf(serveur), isFalse);
      expect(itemAt(kFinances).visibleIf(serveur), isFalse);
    });
  });

  group('Les pastilles ne se trompent plus d\'écran', () {
    test('Stock porte une pastille, Finances aussi', () {
      // Les alertes de réserve comptaient sous une entrée qui parle d'argent :
      // elles envoyaient le gérant au mauvais écran.
      expect(itemAt(kStock).badge, isNotNull);
      expect(itemAt(kFinances).badge, isNotNull);
    });
  });

  group('La barre du bas ne déborde pas', () {
    test('le restaurant garde cinq entrées principales', () {
      // Stock n'est PAS `primary` : une sixième pastille en bas d'un téléphone
      // rendrait les cinq autres illisibles.
      final primaries = kShellNavItems
          .where((i) => i.primary && i.matchesSector('restaurant'))
          .map((i) => i.route('shop_1'))
          .toList();
      expect(primaries.length, 5);
      expect(primaries, isNot(contains(kStock)));
    });
  });
}
