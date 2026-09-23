// Deux serveurs sur la même table : l'un efface les couverts de l'autre.
//
// L'audit disait « ils ne se voient pas ». C'est FAUX : `restaurant_tables`
// est abonnée au temps réel, et `app_database.dart` le justifie à l'endroit
// même — « deux appareils manipulent le même plan de salle simultanément ».
//
// Ce qui ne se voit pas, c'est l'instant de la validation. La feuille de prise
// de commande travaille sur l'objet capturé à son OUVERTURE. B choisit Table 4,
// alors libre ; A l'ouvre pour 4 couverts pendant que B compose ; B valide, et
// le calcul « couverts assis + nouvelle tablée » se fait sur l'instantané, où
// la table était libre. B écrit 0 + 3 = 3. Les quatre couverts de A
// disparaissent, sans un mot.
//
// Les deux COMMANDES survivent — ce sont des `Sale` distincts, regroupés par
// compte. C'est l'état de salle qui se perd : le plan ment sur les places
// libres, et le service place des clients sur des chaises occupées.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/restaurant/domain/table_drift.dart';

void main() {
  group('Rien n\'a bougé', () {
    test('le cas normal ne dit rien', () {
      // Un message à chaque commande cesserait d'être lu au bout d'un service.
      expect(
          tableDriftMessage(
              tableName: 'Table 4', seatedBefore: 4, seatedAfter: 4),
          isNull);
    });

    test('une table libre qui le reste ne dit rien', () {
      expect(
          tableDriftMessage(
              tableName: 'Table 4', seatedBefore: 0, seatedAfter: 0),
          isNull);
    });
  });

  group('LA TABLE A ÉTÉ OUVERTE ENTRE-TEMPS', () {
    test('le scénario exact du constat', () {
      // LE test de ce lot. B croyait la table libre, A l'a ouverte pour 4.
      final msg = tableDriftMessage(
          tableName: 'Table 4', seatedBefore: 0, seatedAfter: 4);
      expect(msg, isNotNull);
      expect(msg, contains('Table 4'));
    });

    test('le message donne le chiffre RETENU, pas l\'écart', () {
      // Le serveur a besoin de savoir ce que la table porte maintenant, pas
      // de soustraire de tête.
      final msg = tableDriftMessage(
          tableName: 'Table 4', seatedBefore: 2, seatedAfter: 6)!;
      expect(msg, contains('6'));
    });

    test('un seul couvert d\'écart se dit quand même', () {
      expect(
          tableDriftMessage(
              tableName: 'Table 4', seatedBefore: 3, seatedAfter: 4),
          isNotNull);
    });
  });

  group('LA TABLE S\'EST VIDÉE ENTRE-TEMPS', () {
    test('une libération pendant la saisie se dit aussi', () {
      // Plus rare, moins grave, tout aussi silencieux.
      final msg = tableDriftMessage(
          tableName: 'Table 7', seatedBefore: 5, seatedAfter: 0);
      expect(msg, isNotNull);
      expect(msg, contains('libérée'));
    });

    test('les deux sens ne disent pas la même chose', () {
      final ouverte = tableDriftMessage(
          tableName: 'T', seatedBefore: 0, seatedAfter: 4);
      final liberee = tableDriftMessage(
          tableName: 'T', seatedBefore: 4, seatedAfter: 0);
      expect(ouverte, isNot(liberee));
    });
  });
}
