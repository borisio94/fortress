// Agrégats du tableau de bord restaurant.
//
// Le calcul lui-même vit dans un provider qui lit Hive — non testable sans
// initialiser Hive. On verrouille ici le CONTRAT du modèle, en particulier
// les deux pièges arithmétiques : division par zéro sur une boutique neuve,
// et pourcentages qui doivent retomber sur 100.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/restaurant/data/restaurant_dashboard_providers.dart';

void main() {
  group('RestaurantDashData — répartition par canal', () {
    test('boutique sans commande : aucun pourcentage, aucune division par 0',
        () {
      const d = RestaurantDashData();
      expect(d.totalOrders, 0);
      // Le piège : `count / totalOrders` lèverait ou renverrait NaN, ce qui
      // afficherait « NaN % » dans la légende de l'anneau.
      expect(d.pctOf(0), 0);
      expect(d.pctOf(5), 0);
    });

    test('le total agrège bien les trois canaux', () {
      const d = RestaurantDashData(dineIn: 6, takeaway: 3, delivery: 1);
      expect(d.totalOrders, 10);
    });

    test('les pourcentages somment à 100', () {
      const d = RestaurantDashData(dineIn: 6, takeaway: 3, delivery: 1);
      expect(d.pctOf(d.dineIn), 60);
      expect(d.pctOf(d.takeaway), 30);
      expect(d.pctOf(d.delivery), 10);
      final somme =
          d.pctOf(d.dineIn) + d.pctOf(d.takeaway) + d.pctOf(d.delivery);
      expect(somme, closeTo(100, 0.001));
    });

    test('un canal unique représente 100 %', () {
      const d = RestaurantDashData(dineIn: 4);
      expect(d.pctOf(d.dineIn), 100);
      expect(d.pctOf(d.takeaway), 0);
    });
  });

  group('Défauts du modèle', () {
    test('la série hebdomadaire fait 7 cases à zéro', () {
      const d = RestaurantDashData();
      // L'histogramme indexe par `weekday - 1` : une liste plus courte
      // provoquerait un RangeError au premier rendu.
      expect(d.ordersByWeekday, hasLength(7));
      expect(d.ordersByWeekday.every((v) => v == 0), isTrue);
    });

    test('les compteurs d\'état sont à zéro par défaut', () {
      const d = RestaurantDashData();
      expect(d.inKitchen, 0);
      expect(d.busyTables, 0);
      expect(d.totalTables, 0);
    });
  });

  group('Libellés de jours', () {
    test('7 libellés, lundi en tête', () {
      // L'ordre doit correspondre à `DateTime.weekday` (1 = lundi), sinon
      // les barres seraient décalées d'un jour.
      expect(kWeekdayLabels, hasLength(7));
      expect(kWeekdayLabels.first, 'Lun');
      expect(kWeekdayLabels.last, 'Dim');
    });

    test('l\'index dérivé de weekday tombe juste', () {
      final lundi = DateTime(2026, 7, 20);
      final dimanche = DateTime(2026, 7, 26);
      expect(lundi.weekday, DateTime.monday);
      expect(kWeekdayLabels[(lundi.weekday - 1) % 7], 'Lun');
      expect(kWeekdayLabels[(dimanche.weekday - 1) % 7], 'Dim');
    });
  });
}
