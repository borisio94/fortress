// Un serveur ne pouvait pas atteindre l'écran où l'on prend une commande.
//
// L'entrée « Menu » — la carte des plats, et le SEUL endroit d'où part une
// commande au restaurant — était gardée par `isShopAdmin && canViewProducts`.
// Un serveur a le rôle 'user' : `isShopAdmin` est faux, l'entrée disparaît des
// quatre chemins de navigation (barre principale, débordement, tiroir mobile,
// barre latérale — tous appliquent `visibleIf`).
//
// Il y atterrissait quand même à la connexion, parce que `shopLandingRoute`
// renvoie un restaurant sur `/inventaire` et que la route n'a aucun garde.
// Puis il touchait « Salle » ou « Commandes », et n'avait plus AUCUN moyen d'y
// revenir. Cent fois par jour, sur un téléphone, en plein service.
//
// L'écran, lui, savait déjà se tenir : `_onDishTap(p, canEdit)` ouvre la fiche
// au lieu du formulaire quand on n'a pas le droit d'éditer, et la corbeille,
// la disponibilité du jour et le menu de débordement sont gardés un par un.
// C'est la porte d'entrée qui était fermée, pas la pièce.
//
// AUCUN TEST NE PORTAIT SUR LES RÔLES DE NAVIGATION — `shell_nav_sector_test`
// couvre le SECTEUR, pas le rôle. Une régression ici est silencieuse : elle ne
// casse rien, elle retire simplement un écran à quelqu'un.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/permisions/app_permissions.dart';
import 'package:fortress/core/permisions/user_plan.dart';
import 'package:fortress/shared/navigation/shell_nav_items.dart';

const _shop = 's1';

/// Un SERVEUR : membre de la boutique, rôle 'user', aucune permission
/// explicite. C'est le préréglage le plus courant d'une salle.
AppPermissions get _serveur =>
    AppPermissions(plan: UserPlan.empty(), shopRole: 'user');

/// Le GÉRANT, pour vérifier qu'on ne lui retire rien au passage.
///
/// Avec un abonnement ACTIF, et c'est nécessaire : `canManageStock` et les
/// autres permissions d'écriture passent par `hasActiveSubscription`. Un plan
/// vide masquerait l'entrée Stock pour une raison qui n'a rien à voir avec le
/// rôle, et le test accuserait le mauvais coupable.
AppPermissions get _gerant => const AppPermissions(
      plan: UserPlan(plan: PlanName.business, subStatus: 'active'),
      shopRole: 'admin',
    );

/// Les entrées sont repérées par leur ROUTE et non par leur libellé : le
/// libellé passe par `AppLocalizations`, la route est une chaîne stable.
ShellNavItem _itemAt(String route) => kShellNavItems.firstWhere(
      (i) => i.route(_shop) == route && (i.sectorIn?.isNotEmpty ?? false),
      orElse: () => throw StateError('aucune entrée restaurant sur $route'),
    );

void main() {
  group('Ce qu\'un serveur doit atteindre', () {
    test('LE MENU — le seul écran d\'où part une commande', () {
      // LE test de ce lot. Sans cette entrée, la prise de commande est
      // inatteignable pour la personne dont c'est le métier.
      expect(_itemAt('/shop/$_shop/inventaire').visibleIf(_serveur), isTrue);
    });

    test('le plan de salle — déjà ouvert, on s\'aligne dessus', () {
      // La référence. Son commentaire dit depuis longtemps : « Les serveurs
      // (rôle 'user') doivent pouvoir ouvrir le plan de salle : on s'aligne
      // sur la permission caisse plutôt que sur isShopAdmin. » Le Menu ne
      // s'était pas aligné.
      expect(
          _itemAt('/shop/$_shop/restaurant/tables').visibleIf(_serveur), isTrue);
    });

    test('les commandes — la chronologie du service et l\'encaissement', () {
      expect(_itemAt('/shop/$_shop/caisse/orders').visibleIf(_serveur), isTrue);
    });

    test('LES TROIS ENSEMBLE — le parcours de service est complet', () {
      // L'invariant qui referme la classe de défaut. Prendre une commande,
      // suivre la salle, encaisser : les trois écrans forment un parcours, et
      // il ne vaut rien s'il en manque un. Les tester séparément laisserait
      // passer le cas où l'on en rouvre deux sur trois.
      for (final route in [
        '/shop/$_shop/inventaire',
        '/shop/$_shop/restaurant/tables',
        '/shop/$_shop/caisse/orders',
      ]) {
        expect(_itemAt(route).visibleIf(_serveur), isTrue, reason: route);
      }
    });
  });

  group('Ce qu\'un serveur ne doit PAS atteindre', () {
    test('les finances restaurant restent fermées', () {
      // Ouvrir la carte ne doit pas ouvrir les marges. Si ce test tombe en
      // même temps que celui du Menu, c'est qu'on a élargi trop loin.
      expect(_itemAt('/shop/$_shop/restaurant/finances').visibleIf(_serveur),
          isFalse);
    });

    test('le stock reste fermé', () {
      // `canManageStock` — compter la réserve n'est pas un geste de service.
      expect(
          _itemAt('/shop/$_shop/restaurant/stock').visibleIf(_serveur), isFalse);
    });
  });

  group('Le gérant ne perd rien', () {
    test('il garde les cinq entrées du module', () {
      for (final route in [
        '/shop/$_shop/inventaire',
        '/shop/$_shop/restaurant/tables',
        '/shop/$_shop/caisse/orders',
        '/shop/$_shop/restaurant/finances',
        '/shop/$_shop/restaurant/stock',
      ]) {
        expect(_itemAt(route).visibleIf(_gerant), isTrue, reason: route);
      }
    });
  });
}
