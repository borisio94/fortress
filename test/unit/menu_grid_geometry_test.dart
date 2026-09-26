// La grille du Menu calcule la hauteur des tuiles ; la tuile rend ses lignes.
// Les deux doivent tomber juste — ce test verrouille le calcul.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/restaurant/domain/menu_grid_geometry.dart';

double id(double v) => v;

void main() {
  group('Colonnes', () {
    test('téléphone : deux colonnes, jamais une', () {
      expect(menuGridLayout(328).cols, 2);
      expect(menuGridLayout(200).cols, 2);
    });

    test('quatre colonnes dès ~860 dp de contenu', () {
      expect(menuGridLayout(859).cols, 4);
      expect(menuGridLayout(799).cols, 3);
    });

    test('huit au plus, même sur un très grand écran', () {
      expect(menuGridLayout(3000).cols, 8);
    });
  });

  group('Photo', () {
    test('plafonnée à 150 sur une tuile large', () {
      // 1 100 dp → 5 colonnes de 208,8 dp → 162,9 au ratio → plafonné.
      expect(menuGridLayout(1100).photoHeight, 150);
    });

    test('le plafond ne s\'atteint pas toujours : c\'est un ratio', () {
      // 1 000 dp → 5 colonnes de 188,8 dp → 147,3. Pas 150 : une largeur de
      // colonne plus étroite donne une photo plus basse, et c'est voulu.
      expect(menuGridLayout(1000).photoHeight, closeTo(147.26, 0.01));
    });

    test('suit la largeur en dessous — pas de carré sur téléphone', () {
      final l = menuGridLayout(328); // tuiles de 157 dp
      expect(l.photoHeight, closeTo(l.tileWidth * kMenuPhotoRatio, 0.001));
      expect(l.photoHeight, lessThan(l.tileWidth));
    });

    test('jamais sous 104', () {
      expect(menuGridLayout(200).photoHeight, greaterThanOrEqualTo(104));
    });
  });

  group('Hauteur de tuile', () {
    test('somme des lignes de la tuile, au facteur de police 1', () {
      // 150 + 8 + 17,4 + 2 + 13 + 2 + 21,6 + 4
      expect(menuTileHeight(150, id), closeTo(218.0, 0.01));
    });

    test('le texte grandit avec la police, la photo non', () {
      final base = menuTileHeight(150, id);
      final big = menuTileHeight(150, (v) => v * 1.3);
      expect(big - base, closeTo((12 * 1.45 + 10 * 1.3 + 16 * 1.35) * 0.3, 0.01));
    });
  });
}
