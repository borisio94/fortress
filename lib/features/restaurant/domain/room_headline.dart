/// L'EN-TÊTE COMPTÉ du plan de salle — règle pure, sans Flutter ni Hive.
///
/// « 6 tables · 2 occupées · 22 places, 6 assises » : l'écran dit son état
/// avant qu'on lise une seule carte. Un serveur qui entre en salle veut savoir
/// s'il reste de la place, pas parcourir la grille pour le deviner.
library;

/// Ce qu'une table apporte au décompte.
///
/// [inService] est décidé par l'ÉCRAN, avec la même règle que la carte (statut
/// déduit des commandes ouvertes, réservation périmée retombée sur « Libre ») :
/// l'en-tête ne doit jamais compter une table que la grille montre autrement.
typedef RoomTableFact = ({int capacity, int? covers, bool inService});

/// Décompte de la salle.
///
/// Une table RÉSERVÉE n'est pas « occupée » et personne n'y est « assis » : la
/// chaise est retenue, pas prise. Une table en service sans couverts
/// renseignés compte PLEINE — même hypothèse prudente que `computeSeating`.
({int tables, int occupied, int places, int seated}) roomCount(
    List<RoomTableFact> tables) {
  var occupied = 0;
  var places = 0;
  var seated = 0;
  for (final t in tables) {
    places += t.capacity;
    if (!t.inService) continue;
    occupied++;
    final c = t.covers ?? t.capacity;
    seated += c > t.capacity ? t.capacity : c;
  }
  return (
    tables: tables.length,
    occupied: occupied,
    places: places,
    seated: seated,
  );
}

String _n(int n, String one, String many) => '$n ${n > 1 ? many : one}';

/// « 6 tables · 2 occupées · 22 places, 6 assises ».
///
/// Salle vide : « 6 tables · aucune occupée · 22 places » — un « 0 assise »
/// ne dirait rien de plus que « aucune occupée ».
String roomHeadline(List<RoomTableFact> tables) {
  final c = roomCount(tables);
  final head = _n(c.tables, 'table', 'tables');
  final places = _n(c.places, 'place', 'places');
  if (c.occupied == 0) return '$head · aucune occupée · $places';
  return '$head · ${_n(c.occupied, 'occupée', 'occupées')} · '
      '$places, ${_n(c.seated, 'assise', 'assises')}';
}
