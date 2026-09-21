// Une vente ne peut pas appartenir à deux jours.
//
// Vingt-deux endroits comparent une date à une fenêtre, et la convention
// dominante était `[from, to]` — bornes INCLUSES des deux côtés. Or les
// fenêtres s'enchaînent : « Hier » finit à minuit, « Aujourd'hui » commence à
// minuit. Une vente enregistrée à exactement 00:00:00.000 était donc dans les
// DEUX.
//
// Le cas n'est pas d'école : une commande transférée en cuisine à minuit pile,
// un règlement automatique, un horodatage arrondi — il suffit d'une fois pour
// qu'un total ne tombe plus juste, et rien ne le signale.
//
// RÈGLE RETENUE : demi-ouverte, `[from, to)`. La borne haute appartient à la
// fenêtre SUIVANTE. Les périodes s'enchaînent alors sans trou ni recouvrement,
// et le double comptage devient impossible par construction plutôt que par
// vigilance.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/utils/date_window.dart';
import 'package:fortress/features/dashboard/data/dashboard_providers.dart';

void main() {
  final minuit = DateTime(2026, 9, 21);
  final minuitDemain = DateTime(2026, 9, 22);
  final hier = DashRange(DateTime(2026, 9, 20), minuit);
  final aujourdhui = DashRange(minuit, minuitDemain);

  group('Minuit n\'appartient qu\'à un seul jour', () {
    test('une vente à minuit pile est dans AUJOURD\'HUI', () {
      expect(aujourdhui.contains(minuit), isTrue);
    });

    test('et PAS dans hier', () {
      // LE test rouge. Aujourd'hui elle est dans les deux, et le total du mois
      // la compte deux fois si les deux jours y entrent.
      expect(hier.contains(minuit), isFalse);
    });
  });

  group('Les fenêtres s\'enchaînent sans trou ni recouvrement', () {
    test('chaque instant de la journée tombe dans exactement une fenêtre', () {
      for (final at in [
        DateTime(2026, 9, 20, 23, 59, 59, 999),
        minuit,
        DateTime(2026, 9, 21, 0, 0, 0, 1),
        DateTime(2026, 9, 21, 12),
        DateTime(2026, 9, 21, 23, 59, 59, 999),
      ]) {
        final n = [hier, aujourdhui].where((r) => r.contains(at)).length;
        expect(n, 1, reason: '$at est dans $n fenêtre(s), il en faut une');
      }
    });

    test('la borne haute appartient à la fenêtre suivante', () {
      expect(aujourdhui.contains(minuitDemain), isFalse);
    });
  });

  group('Les bornes FACULTATIVES suivent la même règle', () {
    test('sans borne haute, tout ce qui suit est pris', () {
      // `null` veut dire « pas de borne », et non « borne à maintenant ».
      expect(withinOptionalBounds(DateTime(2030), from: minuit), isTrue);
    });

    test('la borne haute reste exclue', () {
      expect(withinOptionalBounds(minuitDemain, from: minuit, to: minuitDemain),
          isFalse);
      expect(
          withinOptionalBounds(DateTime(2026, 9, 21, 23, 59),
              from: minuit, to: minuitDemain),
          isTrue);
    });

    test('sans aucune borne, tout passe', () {
      expect(withinOptionalBounds(DateTime(1999)), isTrue);
    });
  });

  group('Ce qui ne change pas', () {
    test('le début de fenêtre reste inclus', () {
      expect(aujourdhui.contains(minuit), isTrue);
      expect(hier.contains(DateTime(2026, 9, 20)), isTrue);
    });

    test('un instant hors fenêtre le reste', () {
      expect(aujourdhui.contains(DateTime(2026, 9, 19, 12)), isFalse);
      expect(aujourdhui.contains(DateTime(2026, 9, 23, 12)), isFalse);
    });
  });
}
