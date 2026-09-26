// L'en-tête du plan de salle dit l'état de la salle avant qu'on lise une carte.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/restaurant/domain/room_headline.dart';

RoomTableFact free(int cap) => (capacity: cap, covers: null, inService: false);
RoomTableFact busy(int cap, int? covers) =>
    (capacity: cap, covers: covers, inService: true);

void main() {
  test('la phrase de la maquette', () {
    final tables = [
      busy(4, 2), busy(6, 4), free(4), free(2), free(4), free(2),
    ];
    expect(roomHeadline(tables),
        '6 tables · 2 occupées · 22 places, 6 assises');
  });

  test('salle vide : pas de « 0 assise »', () {
    expect(roomHeadline([free(4), free(2)]),
        '2 tables · aucune occupée · 6 places');
  });

  test('singuliers', () {
    expect(roomHeadline([busy(1, 1)]), '1 table · 1 occupée · 1 place, 1 assise');
  });

  test('couverts non renseignés : la table compte pleine', () {
    expect(roomCount([busy(6, null)]).seated, 6);
  });

  test('couverts au-delà de la capacité : plafonnés', () {
    expect(roomCount([busy(4, 9)]).seated, 4);
  });

  test('une table réservée n\'est ni occupée ni assise', () {
    // La réservation est passée comme `inService: false` par l'écran.
    final c = roomCount([free(6)]);
    expect(c.occupied, 0);
    expect(c.seated, 0);
    expect(c.places, 6);
  });
}
