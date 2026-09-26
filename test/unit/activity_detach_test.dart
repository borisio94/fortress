// Supprimer une activité ne doit laisser ni identifiant mort, ni seconde
// ligne « Sans secteur ».
//
// Sans clé étrangère (offline-first, hotfix_141), un plat pouvait garder
// l'identifiant d'une activité supprimée. Le rapport en faisait une ligne à
// part, nommée elle aussi « Sans secteur », qui comptait comme une activité
// réelle — et pouvait faire réapparaître la carte « Par secteur ».

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/services/activity_service.dart';
import 'package:fortress/core/services/restaurant_reporting_service.dart';

void main() {
  group('Clé de secteur', () {
    const known = {'ra_bar', 'ra_cuisine'};

    test('une activité existante garde sa clé', () {
      expect(RestaurantReportingService.sectorKeyOf('ra_bar', known), 'ra_bar');
    });

    test('un plat sans activité va sous « Sans secteur »', () {
      expect(RestaurantReportingService.sectorKeyOf(null, known), '');
    });

    test('un identifiant ORPHELIN rejoint la même ligne, pas une seconde', () {
      expect(RestaurantReportingService.sectorKeyOf('ra_supprimee', known), '');
    });

    test('sans aucune activité, tout est « Sans secteur »', () {
      expect(RestaurantReportingService.sectorKeyOf('ra_bar', const {}), '');
    });
  });

  group('Ce que la confirmation annonce', () {
    test('rien de rattaché', () {
      expect(ActivityService.attachedLabel(0, 0), isNull);
    });

    test('plats seuls, singulier et pluriel', () {
      expect(ActivityService.attachedLabel(1, 0), '1 plat');
      expect(ActivityService.attachedLabel(4, 0), '4 plats');
    });

    test('articles de stock seuls', () {
      expect(ActivityService.attachedLabel(0, 1), '1 article de stock');
    });

    test('les deux', () {
      expect(ActivityService.attachedLabel(4, 2),
          '4 plats et 2 articles de stock');
    });
  });
}
