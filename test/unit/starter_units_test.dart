// Une boutique neuve n'avait aucune unité.
//
// `LocalStorageService.getUnits` rend la liste stockée sous `units_<shopId>`,
// et `[]` quand la clé est absente — sans aucun repli. `createShop` n'en
// écrivait pas. Le premier produit saisi butait donc sur un champ « unité »
// vide, et il fallait deviner qu'on pouvait en créer, dans un écran de
// paramètres qu'on ne cherche pas quand on remplit une fiche produit.
//
// POURQUOI LES UNITÉS ET PAS LES CATÉGORIES. Une unité ne porte aucun sens
// métier : « kg » est « kg » partout, personne ne la renomme. Une catégorie,
// si — en inventer pour le commerçant l'obligerait à défaire avant de faire.
// Les catégories restent vides à dessein, et c'est leur état vide qui nomme
// la notion.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/config/restaurant_mode.dart';
import 'package:fortress/core/config/starter_units.dart';

void main() {
  group('Ce qu\'une boutique neuve reçoit', () {
    test('UNE BOUTIQUE DE DÉTAIL REÇOIT DES UNITÉS', () {
      // LE test de ce lot. Avant, la liste était vide et le premier produit
      // se heurtait à un champ sans choix.
      expect(starterUnitsFor('ecommerce'), isNotEmpty);
      expect(starterUnitsFor('retail'), isNotEmpty);
    });

    test('UN RESTAURANT EN REÇOIT AUSSI, et ce ne sont pas les mêmes', () {
      // Un ingrédient s'achète au poids, un article de boutique à la pièce.
      // Proposer « carton » à un cuisinier et « sac » à une boutique en ligne
      // ferait chercher dans une liste qui ne parle pas de son métier.
      for (final sector in kRestaurantSectors) {
        expect(starterUnitsFor(sector), isNotEmpty, reason: sector);
        expect(starterUnitsFor(sector), isNot(equals(starterUnitsFor('retail'))),
            reason: sector);
      }
    });

    test('un secteur inconnu ou absent reçoit la liste du détail', () {
      // Repli, pas exception : une boutique legacy au secteur `supermarche`
      // ou `pharmacie` n'a aucune raison de se retrouver sans unités.
      expect(starterUnitsFor('supermarche'), starterUnitsFor('retail'));
      expect(starterUnitsFor(null), starterUnitsFor('retail'));
      expect(starterUnitsFor(''), starterUnitsFor('retail'));
    });
  });

  group('Ce que les listes doivent respecter', () {
    test('aucun doublon, aucune chaîne vide', () {
      // `saveUnit` déduplique à l'écriture, mais une liste fautive ici
      // écrirait quand même une entrée vide dans le menu déroulant.
      for (final list in [kStarterUnitsRetail, kStarterUnitsRestaurant]) {
        expect(list.toSet().length, list.length, reason: '$list');
        expect(list.any((u) => u.trim().isEmpty), isFalse, reason: '$list');
      }
    });

    test('les deux listes restent courtes', () {
      // Une liste d'amorçage n'est pas un catalogue : au-delà d'une poignée,
      // elle devient un formulaire à faire défiler, et le commerçant ne
      // trouve plus la sienne.
      expect(kStarterUnitsRetail.length, lessThanOrEqualTo(8));
      expect(kStarterUnitsRestaurant.length, lessThanOrEqualTo(8));
    });

    test('le poids et le volume figurent des deux côtés', () {
      // Le socle commun. Quel que soit le commerce, on pèse et on verse.
      for (final list in [kStarterUnitsRetail, kStarterUnitsRestaurant]) {
        expect(list, contains('kg'));
        expect(list, contains('L'));
        expect(list, contains('pièce'));
      }
    });
  });
}
