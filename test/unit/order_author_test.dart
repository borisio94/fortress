// Rien ne disait qui avait pris la commande.
//
// La notion existait en entier, et inerte. `Sale.createdByUserId` est un
// champ ; il est écrit dans les quatre cartes de `sale_local_datasource`, lu
// en retour, porté par les DEUX chemins de synchronisation. `bill_page:338`
// affiche même une ligne « Serveur ».
//
// Elle ne s'affichait jamais, pour deux raisons qui se cumulaient :
//
//   * RestaurantOrderService construit ses Sale SANS ce champ. Il vaut donc
//     toujours null au restaurant, et la ligne — conditionnée à sa présence —
//     ne se rend pas ;
//   * et s'il avait été rempli, bill_page affichait `createdByUserId` TEL
//     QUEL, c'est-à-dire un UUID sur l'addition.
//
// Aucune migration n'était nécessaire : la colonne existe et voyage déjà.
// Il manquait l'écriture, et un nom.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/restaurant/domain/order_author.dart';

void main() {
  group('Le libellé de l\'auteur', () {
    test('LE NOM QUAND ON L\'A', () {
      expect(
          serverLabelFor(
              userId: 'u_1', name: 'Awa Ngono', email: 'awa@resto.cm'),
          'Awa Ngono');
    });

    test('JAMAIS L\'IDENTIFIANT, même quand c\'est tout ce qu\'on a', () {
      // LE test de ce lot. Un UUID sur une addition n'apprend rien à personne
      // et donne l'impression d'une fuite technique. Mieux vaut ne rien
      // afficher : la ligne disparaît, exactement comme quand le champ était
      // vide.
      expect(serverLabelFor(userId: 'a3f9c1e2-7b44-4d10-9e21-5c8f0b3a7d66'),
          isNull);
    });

    test('l\'e-mail sert de repli, sans son domaine', () {
      // Une fiche de personnel peut n'avoir jamais reçu de nom. « awa » vaut
      // mieux que rien pour un gérant qui cherche à qui parler, et le domaine
      // est le même pour tout le monde : il ne distingue personne.
      expect(serverLabelFor(userId: 'u_1', email: 'awa@resto.cm'), 'awa');
      expect(serverLabelFor(userId: 'u_1', name: '', email: 'awa@resto.cm'),
          'awa');
    });

    test('le nom l\'emporte sur l\'e-mail', () {
      expect(serverLabelFor(userId: 'u_1', name: 'Awa', email: 'x@y.cm'),
          'Awa');
    });

    test('sans auteur, rien à afficher', () {
      // Le cas de toutes les commandes antérieures à ce lot : le champ est
      // null, et la ligne doit rester absente comme avant.
      expect(serverLabelFor(userId: null, name: 'Awa'), isNull);
      expect(serverLabelFor(userId: '', name: 'Awa'), isNull);
    });

    test('les espaces de bord ne comptent pas', () {
      expect(serverLabelFor(userId: 'u_1', name: '  Awa  '), 'Awa');
      expect(serverLabelFor(userId: 'u_1', name: '   ', email: 'awa@r.cm'),
          'awa');
    });

    test('un e-mail sans arobase est pris tel quel', () {
      // Défensif : la donnée vient d'un profil distant, on ne suppose pas sa
      // forme. Mais on ne rend jamais une chaîne vide.
      expect(serverLabelFor(userId: 'u_1', email: 'awa'), 'awa');
      expect(serverLabelFor(userId: 'u_1', email: '@resto.cm'), isNull);
    });
  });
}
