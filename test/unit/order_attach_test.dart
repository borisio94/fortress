// Ajouter un dessert ne doit pas ajouter un convive.
//
// Il n'existait aucun chemin « ajouter des plats à une commande en cours » :
// le serveur refaisait la prise de commande entière — panier, « Commander »,
// type de service, table, couverts, envoi — pour un seul café. Le raccourci
// ouvert par le constat n° 7 saute quatre de ces cinq questions.
//
// Mais la prise de commande écrit `tableCovers: _seated(table) + _covers`, et
// elle a raison de le faire : asseoir trois convives à une table qui en
// portait cinq doit donner huit. Rejouée pour un dessert, cette même ligne
// ajouterait un couvert par article commandé en cours de repas — une table de
// quatre qui prend trois cafés en afficherait sept, le plan de salle la
// donnerait pleine, et `computeSeating` compterait des places occupées par
// personne.
//
// Le raccourci aurait faussé exactement ce qu'il devait accélérer.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/restaurant/domain/order_attach.dart';

void main() {
  group('Une NOUVELLE tablée — le comportement d\'origine, inchangé', () {
    test('une table libre prend la tablée entière', () {
      final r = coversForTableOrder(
          attaching: false, seated: 0, newCovers: 4);
      expect(r.orderCovers, 4);
      expect(r.tableCovers, 4);
    });

    test('une seconde tablée S\'AJOUTE à celle déjà assise', () {
      // La règle que la prise de commande porte déjà, avec sa raison écrite :
      // sans ce cumul, asseoir 3 convives à une table qui en portait 5 la
      // ramenait à 3, et les cinq premiers disparaissaient du plan de salle.
      final r = coversForTableOrder(
          attaching: false, seated: 5, newCovers: 3);
      expect(r.tableCovers, 8);
      // La commande, elle, ne porte QUE sa propre tablée : c'est pour eux que
      // le bon part en cuisine.
      expect(r.orderCovers, 3);
    });
  });

  group('UN AJOUT à une table déjà ouverte', () {
    test('LA TABLE NE GAGNE AUCUN COUVERT', () {
      // LE test de ce lot. Quatre personnes à table, un dessert de plus : la
      // table porte toujours quatre couverts.
      final r = coversForTableOrder(
          attaching: true, seated: 4, newCovers: 1);
      expect(r.tableCovers, 4);
    });

    test('trois cafés de suite ne font pas sept convives', () {
      // Le calcul est le même à chaque ajout parce qu'il ne dépend pas de ce
      // qui a été saisi : trois passages laissent la table à quatre.
      var seated = 4;
      for (var i = 0; i < 3; i++) {
        seated = coversForTableOrder(
                attaching: true, seated: seated, newCovers: 1)
            .tableCovers;
      }
      expect(seated, 4);
    });

    test('la tablée saisie est IGNORÉE en ajout', () {
      // Le formulaire ne la demande plus, mais une valeur résiduelle ne doit
      // pas pouvoir se glisser dans le calcul.
      final r = coversForTableOrder(
          attaching: true, seated: 6, newCovers: 99);
      expect(r.tableCovers, 6);
      expect(r.orderCovers, 6);
    });

    test('la commande reprend les convives assis, pour le bon de cuisine', () {
      final r = coversForTableOrder(
          attaching: true, seated: 4, newCovers: 1);
      expect(r.orderCovers, 4);
    });

    test('une table occupée SANS couverts renseignés n\'imprime pas « 0 »', () {
      // `kitchen_ticket_card` affiche « ${order.covers} couverts » dès que le
      // champ n'est pas nul. Zéro s'imprimerait, et un cuisinier lirait
      // « 0 couverts » avec du monde en salle.
      final r = coversForTableOrder(
          attaching: true, seated: 0, newCovers: 1);
      expect(r.orderCovers, 1);
      // La table, elle, reste à ce qu'elle était — on n'invente pas un convive
      // sur le plan de salle pour arranger un bon de cuisine.
      expect(r.tableCovers, 0);
    });
  });
}
