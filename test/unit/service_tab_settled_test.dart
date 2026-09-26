// « Active ou soldée » décide de tout le rendu de la grille des commandes :
// surface de carte élevée, ou surface de fond à plat et montant atténué.
//
// Sans ce test, un rang ajouté demain basculerait du mauvais côté en silence.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/restaurant/domain/service_tabs.dart';

void main() {
  test('seules « Encaissées » et « Sans suite » sont soldées', () {
    final soldees = {
      for (final t in ServiceTab.values)
        if (t.isSettled) t,
    };
    expect(soldees, {ServiceTab.encaissees, ServiceTab.sansSuite});
  });

  test('« À encaisser » reste ACTIVE : de l\'argent attend', () {
    expect(ServiceTab.aEncaisser.isSettled, isFalse);
  });

  test('chaque rang de service vivant est actif', () {
    for (final t in [
      ServiceTab.aEnvoyer,
      ServiceTab.enPreparation,
      ServiceTab.aServir,
      ServiceTab.aTerminer,
      ServiceTab.aEncaisser,
    ]) {
      expect(t.isSettled, isFalse, reason: t.label);
    }
  });

  test('un rang inconnu du test fait échouer le test', () {
    // Garde-fou : si un rang est AJOUTÉ à l'enum, ce décompte casse et oblige
    // à décider — ici, explicitement — de quel côté il tombe.
    expect(ServiceTab.values.length, 8);
  });
}
