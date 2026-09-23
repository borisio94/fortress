// Une table oubliée le vendredi soir est encore occupée le lundi.
//
// Le plan de salle n'a jamais rien dit du temps. Une table ouverte depuis dix
// minutes et une table oubliée depuis trois jours s'y affichaient de façon
// strictement identique — même couleur, même libellé, même tout. Aucun
// nettoyage n'existe : le grep de `staleOrders|cleanupOpen|purgeOpen|
// abandonnedOrders|closeStale|endOfDay` sur tout `lib` ne rend rien.
//
// La donnée, elle, était déjà là : `RestaurantTable.openedAt` est écrit à
// l'ouverture et `RestaurantOrderService.mealDuration` la lit — depuis un seul
// appelant, `bill_page.dart`. Le temps n'était donc visible qu'en ouvrant
// l'addition, une table à la fois, c'est-à-dire jamais pour celle que personne
// ne regarde plus.
//
// Ce que ces tests épinglent, c'est la RÈGLE : deux seuils, pas un, et aucune
// libération automatique déduite d'ici.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/restaurant/domain/table_service_age.dart';

/// `now` fixe : sans elle, un test qui passe à 23 h 59 échoue à 0 h 01.
final _now = DateTime(2026, 9, 23, 20, 0);

Duration? _openSince(Duration ago) =>
    tableOpenFor(openedAt: _now.subtract(ago), now: _now);

void main() {
  group('Depuis quand la table est ouverte', () {
    test('une table sans heure d\'ouverture ne dit rien', () {
      expect(tableOpenFor(openedAt: null, now: _now), isNull);
    });

    test('l\'écart se compte depuis l\'ouverture', () {
      expect(_openSince(const Duration(minutes: 25)),
          const Duration(minutes: 25));
    });

    test('une horloge en avance ne produit jamais de durée négative', () {
      // L'ouverture a été écrite par un poste dont l'horloge avance : l'écart
      // est négatif. Mieux vaut ne rien afficher qu'un « −3 h », qui ferait
      // douter de tout le reste de l'écran.
      expect(
          tableOpenFor(
              openedAt: _now.add(const Duration(hours: 3)), now: _now),
          isNull);
    });

    test('l\'instant exact de l\'ouverture vaut zéro, pas null', () {
      expect(tableOpenFor(openedAt: _now, now: _now), Duration.zero);
    });
  });

  group('Les deux seuils', () {
    test('un service ordinaire ne signale rien', () {
      expect(tableServiceOf(const Duration(minutes: 40)),
          TableService.courte);
      expect(tableServiceOf(const Duration(hours: 3, minutes: 59)),
          TableService.courte);
    });

    test('à quatre heures pile, le repas devient LONG', () {
      // La borne est INCLUSIVE, et c'est le sens du seuil : « au-delà de
      // quatre heures » se lit « quatre heures ou plus » par qui regarde
      // l'écran.
      expect(tableServiceOf(kTableServiceLong), TableService.longue);
    });

    test('un repas long reste un fait de service, pas une anomalie', () {
      // La tablée de douze du samedi soir. Elle se signale, elle n'alarme pas.
      expect(tableServiceOf(const Duration(hours: 6)), TableService.longue);
      expect(tableServiceOf(const Duration(hours: 11, minutes: 59)),
          TableService.longue);
    });

    test('à douze heures, LA TABLE EST DORMANTE', () {
      // LE test de ce lot. Douze heures ne peuvent pas s'écouler pendant un
      // service : la table a traversé une fermeture, et plus personne n'y est
      // assis.
      expect(tableServiceOf(kTableServiceDormant), TableService.dormante);
    });

    test('LA TABLE DU VENDREDI SOIR, RETROUVÉE LE LUNDI', () {
      // Le cas qui a motivé tout ce fichier.
      final open = _openSince(const Duration(days: 3));
      expect(open, isNotNull);
      expect(tableServiceOf(open!), TableService.dormante);
    });

    test('les deux seuils sont ordonnés', () {
      // Une inversion à l'édition rendrait « dormante » inatteignable sans
      // qu'aucun autre test ne le voie.
      expect(kTableServiceLong < kTableServiceDormant, isTrue);
    });
  });

  group('Ce que le serveur lit en passant', () {
    test('sous l\'heure, la minute compte', () {
      expect(tableServiceLabel(const Duration(minutes: 0)), '0 min');
      expect(tableServiceLabel(const Duration(minutes: 47)), '47 min');
    });

    test('au-delà, l\'heure suffit', () {
      expect(tableServiceLabel(const Duration(hours: 1)), '1 h');
      expect(
          tableServiceLabel(const Duration(hours: 4, minutes: 5)), '4 h 05');
      expect(
          tableServiceLabel(const Duration(hours: 2, minutes: 30)), '2 h 30');
    });

    test('au-delà du jour, seuls les jours se lisent', () {
      // « 62 h » ne se lit pas d'un coup d'œil ; « 2 j » se comprend sans
      // compter.
      expect(tableServiceLabel(const Duration(days: 2, hours: 14)), '2 j');
      expect(tableServiceLabel(const Duration(days: 1)), '1 j');
    });
  });
}
