// GARDE-FOU — les seuils de largeur du restaurant (document de design § 8,
// lot « seuils de largeur », 26/09/2026).
//
// 1. Un seuil de CONTENU porte un NOM et sa raison, posé à côté de son
//    composant (`kRestoKpiFourColumnsMin`, `kRoomLegendBesideMin`,
//    `kOrderListRowMin`…) : aucune largeur n'est comparée à un nombre écrit
//    en dur. Les seuils d'ÉCRAN sont les trois officiels (600, 720, 900).
// 2. Une décision qui dimensionne un contenu lit son CONTENEUR : seules les
//    décisions sur l'écran ENTIER lisent la largeur d'écran — au restaurant,
//    le volet panier du Menu, et lui seul.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Lectures de la largeur d'ÉCRAN admises : décisions sur l'écran entier.
const _screenWidthAllowed = {
  // Volet panier : plein écran sous `kCartPaneFullWidthBelow`, latéral
  // au-dessus — une décision sur l'écran entier. Dans son propre fichier
  // depuis le lot « classes géantes » (26/09/2026).
  'restaurant_menu_page.cart.dart',
};

final _literalWidth = RegExp(
    r'\b(?:maxWidth|minWidth|width|w)\s*(?:>=|<=|>|<)\s*\d{3,}(?:\.\d+)?\b');
final _screenWidth = RegExp(
    r'MediaQuery\.(?:of\(\w+\)\.size|sizeOf\(\w+\))\.width');

Map<String, String> _restaurantSources() => {
      for (final f in Directory('lib/features/restaurant')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart')))
        f.path.replaceAll(r'\', '/'): f.readAsStringSync(),
    };

List<String> literalThresholds(Map<String, String> sources) => [
      for (final e in sources.entries)
        for (final m in _literalWidth.allMatches(e.value))
          '${e.key}:${'\n'.allMatches(e.value.substring(0, m.start)).length + 1}'
              '  ${m.group(0)}',
    ];

List<String> screenWidthReads(Map<String, String> sources) => [
      for (final e in sources.entries)
        if (!_screenWidthAllowed.any(e.key.endsWith))
          for (final m in _screenWidth.allMatches(e.value))
            '${e.key}:${'\n'.allMatches(e.value.substring(0, m.start)).length + 1}',
    ];

void main() {
  test('aucune largeur comparée à un nombre en dur au restaurant', () {
    expect(literalThresholds(_restaurantSources()), isEmpty,
        reason: 'nommer le seuil à côté de son composant, avec sa raison '
            '(ce qu\'il garantit au-dessus)');
  });

  test('seul le volet panier lit la largeur d\'écran au restaurant', () {
    expect(screenWidthReads(_restaurantSources()), isEmpty,
        reason: 'un contenu lit son conteneur (LayoutBuilder), pas l\'écran');
  });

  test('le garde-fou voit bien ce qu\'il doit voir', () {
    const src = '''
      final wide = c.maxWidth >= 760;
      if (constraints.maxWidth < 1100) {}
      final ok = c.maxWidth >= kRestoKpiFourColumnsMin;
      final cols = (c.maxWidth / 150).floor();
      final w = MediaQuery.of(context).size.width;
      final h = MediaQuery.of(context).size.height;
    ''';
    expect(literalThresholds({'a.dart': src}), hasLength(2));
    expect(screenWidthReads({'a.dart': src}), hasLength(1));
    expect(screenWidthReads({'restaurant_menu_page.cart.dart': src}), isEmpty);
  });
}
