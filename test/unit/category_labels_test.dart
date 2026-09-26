// « Plats » et « plats » sont une seule catégorie — comme « Poulet DG » et
// « poulet dg » sont un seul plat (`nameKey`).

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/restaurant/domain/category_labels.dart';

void main() {
  test('casse, accents et espaces : une seule entrée', () {
    final l = categoryLabels(['Plats', 'plats', ' PLATS ', 'Entrées', 'entrees']);
    expect(l.length, 2);
  });

  test('le libellé retenu est l\'orthographe la plus portée', () {
    final l = categoryLabels(['plats', 'Plats', 'Plats']);
    expect(l.values.single, 'Plats');
  });

  test('à égalité, le premier dans l\'ordre alphabétique', () {
    // Déterministe : deux appareils doivent afficher le même onglet.
    expect(categoryLabels(['plats', 'Plats']).values.single, 'Plats');
    expect(categoryLabels(['Plats', 'plats']).values.single, 'Plats');
  });

  test('vides et null ignorés', () {
    expect(categoryLabels([null, '', '  ']), isEmpty);
  });

  test('des catégories différentes restent différentes', () {
    expect(categoryLabels(['Plats', 'Plateaux']).length, 2);
  });

  test('sameCategory', () {
    expect(sameCategory('Entrées', ' entrees'), isTrue);
    expect(sameCategory('Plats', 'Desserts'), isFalse);
    expect(sameCategory(null, 'Plats'), isFalse);
  });
}
