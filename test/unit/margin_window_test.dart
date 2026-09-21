// Une marge sur trois jours ne veut rien dire.
//
// En mode répartition — le mode par défaut — les achats d'une période sont
// partagés entre les plats vendus de CETTE période. Un marché fait lundi donne
// donc un coût matières énorme lundi et proche de zéro mardi, sur exactement
// les mêmes plats.
//
// La section 6 de la définition financière le tranche : « Une seule fenêtre
// fait autorité : le mois. Aucune marge journalière ou hebdomadaire n'a de
// sens. Toute période plus courte que le mois sert à consulter des volumes —
// nombre de commandes, ventes encaissées — pas des marges. »
//
// L'écran affichait pourtant bénéfice, marge brute et food cost sur
// « Aujourd'hui » et « Hier », où le chiffre est du bruit qu'on lit comme une
// mesure.
//
// LA RÈGLE PORTE SUR LA NATURE DE LA PÉRIODE, pas sur sa durée écoulée. Le
// mois civil commence le 1er : juger ce qu'il s'en est écoulé masquerait les
// marges vingt-huit jours sur trente, sur la seule fenêtre que la section 6
// rend autoritaire. Seule la période LIBRE se juge à la durée — elle
// n'annonce aucune intention.
//
// LES VOLUMES RESTENT VISIBLES PARTOUT. « Hier » sert tous les matins : ce
// sont les ventes encaissées qu'on y cherche, pas une rentabilité.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/dashboard/data/dashboard_providers.dart';
import 'package:fortress/features/restaurant/domain/margin_window.dart';

DashRange days(int n) {
  final to = DateTime(2026, 9, 21);
  return DashRange(to.subtract(Duration(days: n)), to);
}

void main() {
  group('Les périodes trop courtes', () {
    test('aujourd\'hui ne porte aucune marge', () {
      // Un marché fait ce jour-là écrase le taux ; le lendemain il tombe à
      // zéro. Le chiffre existe, il ne mesure rien.
      expect(marginsMakeSenseOn(DashPeriod.today, days(1)), isFalse);
    });

    test('hier non plus', () {
      expect(marginsMakeSenseOn(DashPeriod.yesterday, days(1)), isFalse);
    });

    test('la semaine non plus', () {
      expect(marginsMakeSenseOn(DashPeriod.week, days(7)), isFalse);
    });
  });

  group('Les périodes qui portent une marge', () {
    test('le mois, oui — c\'est la fenêtre qui fait autorité', () {
      expect(marginsMakeSenseOn(DashPeriod.month, days(30)), isTrue);
    });

    test('LE MOIS EN COURS AUSSI, même le 3 du mois', () {
      // LE PIÈGE DE CE LOT, et il a été livré une fois avant d'être vu :
      // avec un seuil sur la durée écoulée, « Mois » n'affichait ses marges
      // que les 29 et 30 — l'inverse exact de l'intention.
      expect(marginsMakeSenseOn(DashPeriod.month, days(2)), isTrue);
      expect(marginsMakeSenseOn(DashPeriod.month, days(0)), isTrue);
    });

    test('le trimestre et l\'année, oui', () {
      expect(marginsMakeSenseOn(DashPeriod.quarter, days(90)), isTrue);
      expect(marginsMakeSenseOn(DashPeriod.year, days(365)), isTrue);
      // Eux aussi commencent courts, et pour la même raison ils comptent.
      expect(marginsMakeSenseOn(DashPeriod.quarter, days(5)), isTrue);
    });

    test('une période LIBRE se juge sur sa durée, faute de nature', () {
      // `custom` peut valoir trois jours comme trois ans : elle n'annonce
      // aucune intention, seule sa longueur renseigne.
      expect(marginsMakeSenseOn(DashPeriod.custom, days(3)), isFalse);
      expect(marginsMakeSenseOn(DashPeriod.custom, days(27)), isFalse);
      expect(marginsMakeSenseOn(DashPeriod.custom, days(28)), isTrue);
      expect(marginsMakeSenseOn(DashPeriod.custom, days(120)), isTrue);
    });
  });

  group('Ce qu\'on dit à la place', () {
    test('le message explique POURQUOI, pas seulement que c\'est absent', () {
      final m = marginsUnavailableReason;
      expect(m, isNotEmpty);
      // « Non disponible » ne s'apprend pas. La raison, si.
      expect(m.toLowerCase(), contains('achats'));
      expect(m.toLowerCase(), contains('mois'));
    });
  });
}
