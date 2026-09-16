import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/utils/name_key.dart';

/// COMPARAISON DES NOMS SAISIS À LA MAIN.
///
/// Sert à prévenir qu'un plat du même nom existe déjà. Deux fiches pour le même
/// plat se partagent les ventes : les rapports affichent deux lignes, et si
/// l'une n'a pas de recette, le coût de ses ingrédients se reporte en entier sur
/// l'autre, qui paraît alors bien plus cher qu'il ne l'est.
///
/// Une comparaison brute (`a == b`) ne verrait aucun de ces doublons : ils
/// naissent justement d'une majuscule, d'un accent oublié ou d'un espace de
/// trop, tapés par deux personnes différentes en plein service.
void main() {
  group('Clé de comparaison des noms', () {
    test('la casse ne distingue pas deux plats', () {
      expect(nameKey('Poulet DG'), nameKey('poulet dg'));
      expect(nameKey('POULET DG'), nameKey('Poulet Dg'));
    });

    test('les accents non plus', () {
      expect(nameKey('Ndolè'), nameKey('Ndole'));
      expect(nameKey('Bœuf sauté'), nameKey('Bœuf saute'));
      expect(nameKey('Crème brûlée'), nameKey('Creme brulee'));
    });

    test('les espaces en trop non plus', () {
      expect(nameKey('  Poulet   DG  '), nameKey('Poulet DG'));
      expect(nameKey('Poulet\tDG'), nameKey('Poulet DG'));
    });

    test('deux plats réellement différents restent différents', () {
      expect(nameKey('Poulet DG'), isNot(nameKey('Poisson DG')));
      expect(nameKey('Ndolè viande'), isNot(nameKey('Ndolè crevettes')));
    });

    test('un nom vide ou en blancs donne une clé vide', () {
      // L'appelant s'en sert pour ne rien signaler tant que le champ est vide.
      expect(nameKey(''), isEmpty);
      expect(nameKey('   '), isEmpty);
    });

    test('les chiffres et la ponctuation sont conservés', () {
      // « Menu 1 » et « Menu 2 » sont deux plats : la clé ne doit pas les
      // rapprocher.
      expect(nameKey('Menu 1'), isNot(nameKey('Menu 2')));
      expect(nameKey('Jus d\'ananas'), nameKey('JUS D\'ANANAS'));
    });
  });
}
