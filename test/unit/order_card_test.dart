import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/restaurant/domain/order_tile.dart';
import 'package:fortress/features/restaurant/domain/service_wait.dart';

/// Refonte de la carte de commande (restaurant, 25/09/2026) — ce qui s'en
/// sort en règle pure.
void main() {
  group('formatServiceWait — le chronomètre en mots courts', () {
    test('sous une minute : « < 1 min », jamais « 0 min »', () {
      expect(formatServiceWait(Duration.zero), '< 1 min');
      expect(formatServiceWait(const Duration(seconds: 59)), '< 1 min');
    });

    test('en minutes jusqu\'à l\'heure', () {
      expect(formatServiceWait(const Duration(minutes: 1)), '1 min');
      expect(formatServiceWait(const Duration(minutes: 24)), '24 min');
      expect(formatServiceWait(const Duration(minutes: 59)), '59 min');
    });

    test('au-delà : heures et minutes sur deux chiffres', () {
      expect(formatServiceWait(const Duration(minutes: 60)), '1 h 00');
      expect(formatServiceWait(const Duration(minutes: 65)), '1 h 05');
      expect(formatServiceWait(const Duration(hours: 9, minutes: 2)),
          '9 h 02');
    });
  });

  group('kOrderListRowMin — déduit des colonnes, pas choisi', () {
    test('462 px de colonnes fixes + 160 de contenu', () {
      expect(kOrderListRowMin, 622);
    });

    test('la grille et la liste ne se contredisent pas', () {
      // Deux colonnes de tuiles exigent au moins deux planchers : à cette
      // largeur, la liste tient aussi sur une ligne.
      expect(2 * kOrderTileMin, greaterThan(kOrderListRowMin));
    });
  });
}
