// Filtrage de la navigation par secteur de boutique.
//
// Deux mécanismes complémentaires sur `ShellNavItem` :
//   * `sectorIn`    → item RÉSERVÉ à certains secteurs (Plan de salle…)
//   * `sectorNotIn` → item MASQUÉ dans certains secteurs (CRM, Historique…)
//
// Une régression ici est silencieuse : elle ne casse rien, elle fait juste
// apparaître ou disparaître des modules entiers du menu.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/config/restaurant_mode.dart';
import 'package:fortress/shared/navigation/shell_nav_items.dart';

void main() {
  ShellNavItem itemWith({Set<String>? inSectors, Set<String>? notIn}) =>
      ShellNavItem(
        icon: Icons.abc,
        iconSelected: Icons.abc,
        label: (_) => 'x',
        route: (_) => '/x',
        visibleIf: (_) => true,
        sectorIn: inSectors,
        sectorNotIn: notIn,
      );

  group('matchesSector', () {
    test('sans contrainte, l\'item passe partout', () {
      final item = itemWith();
      for (final s in ['ecommerce', 'restaurant', 'fastfood', 'retail', '']) {
        expect(item.matchesSector(s), isTrue);
      }
    });

    test('sectorIn réserve l\'item aux secteurs listés', () {
      final item = itemWith(inSectors: kRestaurantSectors);
      expect(item.matchesSector('restaurant'), isTrue);
      expect(item.matchesSector('fastfood'), isTrue);
      expect(item.matchesSector('ecommerce'), isFalse);
      expect(item.matchesSector(''), isFalse);
    });

    test('sectorNotIn masque l\'item dans les secteurs listés', () {
      final item = itemWith(notIn: kRestaurantSectors);
      expect(item.matchesSector('restaurant'), isFalse);
      expect(item.matchesSector('fastfood'), isFalse);
      // Non-régression e-commerce : l'item reste visible partout ailleurs.
      expect(item.matchesSector('ecommerce'), isTrue);
      expect(item.matchesSector('retail'), isTrue);
      expect(item.matchesSector(''), isTrue);
    });

    test('sectorNotIn l\'emporte sur sectorIn', () {
      // Combinaison contradictoire : l'exclusion doit gagner, sinon un item
      // pourrait réapparaître là où on l'a explicitement banni.
      final item = itemWith(
          inSectors: {'restaurant'}, notIn: {'restaurant'});
      expect(item.matchesSector('restaurant'), isFalse);
    });
  });

  group('Menu restaurant — composition attendue', () {
    List<String> labelsFor(String sector) => kShellNavItems
        .where((i) => i.matchesSector(sector))
        .map((i) => i.route('shop_1'))
        .toList();

    test('le menu restaurant suit la maquette de référence', () {
      final routes = labelsFor('restaurant');
      // Plan de salle · Menu · Commandes · Analyses · Équipe
      // (+ Paramètres et Abonnement, rendus dans le pied de la sidebar).
      //
      // « MESSAGERIE » A ÉTÉ RETIRÉE du menu restaurant : personne n'ouvre de
      // ticket depuis une salle, et l'entrée encombrait un tiroir que le
      // service parcourt entre deux tables. Elle reste en e-commerce. Le
      // détail — et le fait que les notifications de ticket continuent —
      // est dans `shell_nav_group_test`.
      //
      // « Service » a été RETIRÉ du menu au profit de « Plan de salle » : la
      // prise de commande est passée au Menu (panier → type de service →
      // cuisine), l'écran de service faisait donc doublon. Le plan de salle
      // reste le SEUL endroit où une table se crée.
      expect(routes, contains('/shop/shop_1/restaurant/tables'));
      expect(routes, isNot(contains('/shop/shop_1/restaurant/service')));
      expect(routes, contains('/shop/shop_1/inventaire'));   // « Menu »
      expect(routes, contains('/shop/shop_1/caisse/orders')); // « Commandes »
      expect(routes, contains('/shop/shop_1/employees'));    // « Équipe »
      expect(routes, isNot(contains('/shop/shop_1/tickets')));
      expect(routes, contains('/shop/shop_1/parametres'));
    });

    test('ni « Préparation » ni « À emporter » ne sont au menu', () {
      final routes = labelsFor('restaurant');
      // « Préparation » RETIRÉ (2026-08-05) : le cuisinier annonce à voix
      // haute, l'opérateur fait avancer le bon depuis Commandes, qui porte
      // déjà toute la chronologie du service.
      expect(routes, isNot(contains('/shop/shop_1/restaurant/cuisine')));
      // « À emporter » RETIRÉ : une commande de comptoir peut sortir de
      // n'importe quel poste, elle part en préparation comme les autres et se
      // suit depuis Commandes.
      expect(routes, isNot(contains('/shop/shop_1/restaurant/takeaway')));
      // Commandes reste, et reste l'unique destination du service.
      expect(routes, contains('/shop/shop_1/caisse/orders'));
      // Caisse reste remplacée par « Commandes » en restauration.
      expect(routes, isNot(contains('/shop/shop_1/caisse')));
    });

    test('« Menu » restaurant = entrée simple, « Inventaire » e-commerce = groupe', () {
      // DEUX items DISTINCTS partagent la route /inventaire (même page) :
      //   · le Menu restaurant (sectorIn restaurant), placé juste après le
      //     Tableau de bord — entrée simple, aucun sous-item ;
      //   · l'Inventaire e-commerce (sectorNotIn restaurant) — groupe dépliable
      //     à 3 sous-items (Produits · Emplacements · Incidents).
      final items = kShellNavItems
          .where((i) => i.route('shop_1') == '/shop/shop_1/inventaire')
          .toList();
      expect(items, hasLength(2));

      // Menu restaurant : visible en restauration uniquement, sans sous-item
      // (sinon on afficherait un chevron qui déplierait le vide).
      final restoMenu = items.firstWhere((i) => i.matchesSector('restaurant'));
      expect(restoMenu.matchesSector('ecommerce'), isFalse);
      expect(restoMenu.hasChildrenIn('restaurant'), isFalse);
      expect(restoMenu.childrenFor('restaurant'), isEmpty);

      // Inventaire e-commerce : masqué en restauration, groupe à 3 sous-items.
      final ecomInv = items.firstWhere((i) => i.matchesSector('ecommerce'));
      expect(ecomInv.matchesSector('restaurant'), isFalse);
      expect(ecomInv.hasChildrenIn('ecommerce'), isTrue);
      expect(ecomInv.childrenFor('ecommerce'), hasLength(3));
    });

    test('le restaurant masque CRM, historique, finances et WhatsApp', () {
      final routes = labelsFor('restaurant');
      expect(routes, isNot(contains('/shop/shop_1/crm')));
      expect(routes, isNot(contains('/shop/shop_1/historique')));
      expect(routes, isNot(contains('/shop/shop_1/finances')));
      expect(routes,
          isNot(contains('/shop/shop_1/parametres/whatsapp-templates')));
    });

    test('l\'e-commerce est INCHANGÉ', () {
      final routes = labelsFor('ecommerce');
      // Aucun module restaurant ne doit fuiter côté boutique…
      expect(routes, isNot(contains('/shop/shop_1/restaurant/service')));
      expect(routes, isNot(contains('/shop/shop_1/restaurant/tables')));
      expect(routes, isNot(contains('/shop/shop_1/restaurant/cuisine')));
      // …et rien de l'existant ne doit avoir disparu.
      expect(routes, contains('/shop/shop_1/caisse'));
      expect(routes, contains('/shop/shop_1/crm'));
      expect(routes, contains('/shop/shop_1/finances'));
      expect(routes,
          contains('/shop/shop_1/parametres/whatsapp-templates'));
      expect(routes, contains('/shop/shop_1/historique'));
      expect(routes, contains('/shop/shop_1/tickets'));
      expect(routes, contains('/shop/shop_1/inventaire'));
      // « Commandes » et « Équipe » sont propres au restaurant : ils ne
      // doivent pas apparaître en e-commerce, qui a déjà Caisse › Commandes
      // et CRM › Membres.
      expect(routes, isNot(contains('/shop/shop_1/caisse/orders')));
      expect(routes, isNot(contains('/shop/shop_1/employees')));
    });
  });
}
