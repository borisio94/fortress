// GARDE-FOU — le domaine du restaurant est du Dart pur (lot « domaine sans
// Flutter », 26/09/2026 ; CLAUDE.md : « domain/ — pure Dart, no Flutter »).
//
// Le domaine dit CE QUE sont les choses (un statut de table, une catégorie de
// dépense) ; la présentation dit À QUOI elles ressemblent (couleur, icône) :
// `table_status_visuals.dart`, `expense_kind_visuals.dart`,
// `service_tab_visuals.dart`. Aucune icône ni couleur n'est stockée — les
// entités se sérialisent par leurs clés.
//
// Hors du restaurant, cinq fichiers de domaine importent encore Flutter
// (`sale.dart`, `expense.dart`, `invoice_theme.dart`,
// `order_receipt_usecase.dart`, `product.dart`) : au backlog.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final _flutterImport = RegExp(r'''^import\s+['"]package:flutter/''', multiLine: true);

List<String> flutterInDomain(String root) => [
      for (final f in Directory(root)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart')))
        if (_flutterImport.hasMatch(f.readAsStringSync()))
          f.path.replaceAll(r'\', '/'),
    ];

void main() {
  test('aucun fichier du domaine restaurant n\'importe Flutter', () {
    expect(flutterInDomain('lib/features/restaurant/domain'), isEmpty,
        reason: 'la couleur et l\'icône vivent en présentation '
            '(extension *Visuals), pas dans le domaine');
  });
}
