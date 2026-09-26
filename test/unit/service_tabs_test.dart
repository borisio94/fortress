// « Programmée » contenait une commande déjà servie.
//
// L'écran Commandes filtrait sur `SaleStatus` : six onglets, un par statut.
// C'est juste en e-commerce, où le statut porte l'avancement. En restauration,
// le statut ne bouge qu'à l'encaissement — toute la chronologie du service vit
// dans des drapeaux (`sentToKitchen`, `kitchenReady`, `served`, `finished`) À
// L'INTÉRIEUR de `scheduled`.
//
// Résultat : un onglet contenait aussi bien une commande que personne n'avait
// envoyée en cuisine qu'un client finissant son dessert, pendant que
// « En cours » et « Refusée » restaient vides toute l'année.
//
// Ce que ces tests épinglent : LA CASCADE, qui est celle du bouton de
// chronologie — un onglet, un bouton — et son EXHAUSTIVITÉ, qui garantit qu'un
// statut ajouté demain ne disparaîtra pas en silence.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/caisse/domain/entities/sale.dart';
import 'package:fortress/features/restaurant/domain/service_tabs.dart';

/// Une commande de salle, au rang qu'on lui donne.
///
/// `status: scheduled` par défaut : c'est là que TOUT le service se passe, et
/// c'est précisément ce que l'ancien découpage ne savait pas distinguer.
Sale _order({
  SaleStatus status = SaleStatus.scheduled,
  bool sentToKitchen = false,
  bool kitchenReady = false,
  bool served = false,
  bool finished = false,
  String orderType = 'dine_in',
}) =>
    Sale(
      shopId: 's1',
      items: const [],
      paymentMethod: PaymentMethod.cash,
      createdAt: DateTime(2026, 9, 23, 19, 42),
      status: status,
      orderType: orderType,
      sentToKitchen: sentToKitchen,
      kitchenReady: kitchenReady,
      served: served,
      finished: finished,
    );

void main() {
  group('Les cinq échelons du bouton, un par onglet', () {
    test('rien n\'est parti en préparation → À envoyer', () {
      // Le cas d'une commande arrivée du catalogue web que personne n'a
      // acquittée. C'est une alerte, pas une étape.
      expect(serviceTabOf(_order()), ServiceTab.aEnvoyer);
    });

    test('la cuisine travaille → En préparation', () {
      expect(serviceTabOf(_order(sentToKitchen: true)),
          ServiceTab.enPreparation);
    });

    test('prête au passe, personne ne l\'a prise → À servir', () {
      // La seconde alerte, et la plus coûteuse : c'est là que des plats
      // refroidissent.
      expect(
          serviceTabOf(_order(sentToKitchen: true, kitchenReady: true)),
          ServiceTab.aServir);
    });

    test('servie mais le repas dure → À terminer', () {
      expect(
          serviceTabOf(_order(
              sentToKitchen: true, kitchenReady: true, served: true)),
          ServiceTab.aTerminer);
    });

    test('le service est clos, l\'argent non → À encaisser', () {
      expect(
          serviceTabOf(_order(
              sentToKitchen: true,
              kitchenReady: true,
              served: true,
              finished: true)),
          ServiceTab.aEncaisser);
    });
  });

  group('À emporter : pas de rang « À servir »', () {
    test('une commande à emporter prête va directement À terminer', () {
      // Comme le bouton, qui borne « Marquer servie » à `dine_in` : une
      // commande à emporter prête n'a personne à qui l'apporter, elle attend
      // qu'on la remette au client.
      expect(
          serviceTabOf(_order(
              sentToKitchen: true,
              kitchenReady: true,
              orderType: 'takeaway')),
          ServiceTab.aTerminer);
    });

    test('une livraison prête aussi', () {
      expect(
          serviceTabOf(_order(
              sentToKitchen: true,
              kitchenReady: true,
              orderType: 'delivery')),
          ServiceTab.aTerminer);
    });
  });

  group('LES FINS DE COURSE PASSENT AVANT LES DRAPEAUX', () {
    test('une commande encaissée ne retombe PAS dans À terminer', () {
      // LE piège de l'ordre des tests. `settleAndRelease` FORCE `served` et
      // `finished` au moment d'encaisser — « une commande encaissée est servie
      // et terminée, par définition ». Si le statut n'était pas lu en premier,
      // une commande réglée réapparaîtrait au milieu du service.
      expect(
          serviceTabOf(_order(
              status: SaleStatus.completed,
              sentToKitchen: true,
              kitchenReady: true,
              served: true,
              finished: true)),
          ServiceTab.encaissees);
    });

    test('une annulation en pleine préparation sort du service', () {
      expect(
          serviceTabOf(_order(
              status: SaleStatus.cancelled, sentToKitchen: true)),
          ServiceTab.sansSuite);
    });

    test('remboursée aussi — sans quoi elle tomberait dans À envoyer', () {
      // Aucun chemin de l'app ne la produit, mais un rang par défaut doit être
      // choisi plutôt que subi : sans drapeaux de cuisine, elle serait tombée
      // dans le premier échelon du service.
      expect(serviceTabOf(_order(status: SaleStatus.refunded)),
          ServiceTab.sansSuite);
    });

    test('refusée rejoint annulée', () {
      // Jamais produite en restauration — elle vient du circuit de livraison
      // e-commerce. Un onglet toujours vide est un onglet qu'on cesse de lire.
      expect(serviceTabOf(_order(status: SaleStatus.refused)),
          ServiceTab.sansSuite);
    });
  });

  group('La cascade est EXCLUSIVE et EXHAUSTIVE', () {
    final toutes = [
      _order(),
      _order(sentToKitchen: true),
      _order(sentToKitchen: true, kitchenReady: true),
      _order(sentToKitchen: true, kitchenReady: true, served: true),
      _order(
          sentToKitchen: true,
          kitchenReady: true,
          served: true,
          finished: true),
      _order(status: SaleStatus.completed),
      _order(status: SaleStatus.cancelled),
      _order(status: SaleStatus.refused),
    ];

    test('la somme des onglets égale le total', () {
      // L'invariant qui protège du silence : un statut ajouté demain sans rang
      // ferait diverger cette somme.
      final counts = serviceTabCounts(toutes);
      var sum = 0;
      for (final t in ServiceTab.ordered) {
        if (t == ServiceTab.toutes) continue;
        sum += counts[t]!;
      }
      expect(sum, toutes.length);
      expect(counts[ServiceTab.toutes], toutes.length);
    });

    test('chaque commande tombe dans UN onglet et un seul', () {
      for (final o in toutes) {
        final hits = ServiceTab.ordered
            .where((t) => t != ServiceTab.toutes)
            .where((t) => ordersForServiceTab(t, [o]).isNotEmpty)
            .toList();
        expect(hits, hasLength(1), reason: 'rangs trouvés : $hits');
      }
    });

    test('« Toutes » ne filtre rien', () {
      expect(ordersForServiceTab(ServiceTab.toutes, toutes),
          hasLength(toutes.length));
    });

    test('un onglet vide rend une liste vide, pas une erreur', () {
      expect(ordersForServiceTab(ServiceTab.aServir, const []), isEmpty);
      expect(serviceTabCounts(const [])[ServiceTab.aServir], 0);
    });
  });

  group('Les libellés n\'empruntent rien aux badges', () {
    test('aucun onglet ne porte un mot de SaleStatus', () {
      // La règle du lot : un onglet ne doit jamais pouvoir se lire comme un
      // badge. « Programmée » et « À encaisser » à trois centimètres l'un de
      // l'autre seraient pires que l'état d'avant.
      final interdits = {
        for (final s in SaleStatus.values) s.label.toLowerCase(),
      };
      for (final t in ServiceTab.ordered) {
        expect(interdits.contains(t.label.toLowerCase()), isFalse,
            reason: '« ${t.label} » est aussi un libellé de statut');
      }
    });
  });

  group('Le badge nomme UNE commande (26/09/2026)', () {
    test('« Encaissée » au singulier, l\u2019onglet garde son pluriel', () {
      expect(ServiceTab.encaissees.badgeLabel, 'Encaissée');
      expect(ServiceTab.encaissees.label, 'Encaissées');
    });

    test('les six autres rangs d\u2019une carte gardent le libellé de '
        'l\u2019onglet', () {
      for (final t in ServiceTab.values) {
        if (t == ServiceTab.encaissees || t == ServiceTab.toutes) continue;
        expect(t.badgeLabel, t.label);
      }
    });
  });
}

