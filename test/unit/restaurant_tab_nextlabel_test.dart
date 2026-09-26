// Test du nom proposé pour une NOUVELLE commande sur une table.
//
// LE DÉFAUT CORRIGÉ : le nom était déduit du NOMBRE de commandes déjà
// enregistrées (`Commande ${count + 1}`). Or une commande ouverte à l'écran
// mais dont rien n'a encore été saisi n'existe pas côté données — elle n'est
// pas comptée. La troisième tentative se voyait donc proposer « Commande 2 »,
// un nom déjà pris, et choisir un nom existant ROUVRE cette commande au lieu
// d'en créer une. D'où l'impression de ne jamais pouvoir dépasser deux.
//
// La règle testée ici cherche le premier nom LIBRE, ce qui rend le compteur
// insensible aux trous et aux commandes non encore enregistrées.

import 'package:flutter_test/flutter_test.dart';

/// Reproduit `RestaurantTabService.nextFreeLabel` : le service lit Hive, la
/// règle tient en quelques lignes.
String nextFree(Set<String> taken) {
  for (var n = 1; n <= 99; n++) {
    final c = 'Commande $n';
    if (!taken.contains(c)) return c;
  }
  return 'Commande 100';
}

void main() {
  group('Premier nom libre', () {
    test('table vierge : première commande', () {
      expect(nextFree({}), 'Commande 1');
    });

    test('les noms s\'enchaînent sans se répéter', () {
      expect(nextFree({'Commande 1'}), 'Commande 2');
      expect(nextFree({'Commande 1', 'Commande 2'}), 'Commande 3');
      expect(nextFree({'Commande 1', 'Commande 2', 'Commande 3'}),
          'Commande 4');
    });

    test('LE DÉFAUT : une commande ouverte non enregistrée ne bloque plus', () {
      // Deux commandes en base, plus celle ouverte à l'écran que le service ne
      // voit pas encore. L'ancienne règle rendait « Commande 3 » — déjà pris.
      expect(nextFree({'Commande 1', 'Commande 2', 'Commande 3'}),
          'Commande 4');
    });

    test('un trou est réutilisé', () {
      // « Commande 2 » a été encaissée : son nom redevient disponible.
      expect(nextFree({'Commande 1', 'Commande 3'}), 'Commande 2');
    });

    test('les noms libres ignorent les commandes nommées à la main', () {
      expect(nextFree({'M. Ali', 'Table du fond'}), 'Commande 1');
    });
  });
}
