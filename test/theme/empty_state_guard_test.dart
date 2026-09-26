// GARDE-FOU — un « rien ici » du restaurant n'est jamais un texte nu
// (lot « états vides », 26/09/2026 ; document de design § 11).
//
// L'écran entier vide → `RestoEmptyState` (une carte). Une liste vide DANS une
// section ou une feuille → `RestoEmptyNote` (une phrase en textSecondary,
// lisible dans les deux modes — ces notes étaient en `captionHint`, dont le
// `textHint` tombe à 3,07:1 en sombre).
//
// CE QU'IL LIT : un `Text(` dont le PREMIER argument est une phrase qui
// commence par « Aucun », « Aucune » ou « Rien », rendue sous une condition
// `…isEmpty` (dans les 300 caractères qui précèdent) — le motif exact d'une
// liste vide. Une phrase en « Aucun » qui EXPLIQUE (« Aucun motif n'est
// demandé : c'est un droit ») n'est pas une liste vide : elle passe, sans
// qu'il faille la lister.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Exception NOMMÉE : `_SuppliesEmptyState`, écrite au § 11, « à ne pas
/// étendre ».
const _allowed = <String>{'Aucune fourniture'};

/// Le texte de la PREMIÈRE chaîne littérale qui suit [from] (échappements
/// compris), ou `null` si ce n'est pas une chaîne entre apostrophes.
String? _firstLiteral(String src, int from) {
  var i = from;
  while (i < src.length && ' \n\r'.contains(src[i])) {
    i++;
  }
  if (i >= src.length || src[i] != "'") return null;
  final out = StringBuffer();
  i++;
  while (i < src.length && src[i] != "'") {
    if (src[i] == r'\' && i + 1 < src.length) {
      out.write(src[i + 1]);
      i += 2;
      continue;
    }
    out.write(src[i]);
    i++;
  }
  return out.toString();
}

List<String> offenders(String path, String src) {
  final out = <String>[];
  for (final m in RegExp(r'\bText\(').allMatches(src)) {
    final lit = _firstLiteral(src, m.end);
    if (lit == null) continue;
    if (!RegExp(r'^(Aucun|Aucune|Rien)\b').hasMatch(lit)) continue;
    if (!lit.contains(' ')) continue; // libellé de puce
    if (_allowed.any(lit.startsWith)) continue;
    final before = src.substring(m.start < 300 ? 0 : m.start - 300, m.start);
    if (!before.contains('isEmpty')) continue; // pas une liste vide
    final line = '\n'.allMatches(src.substring(0, m.start)).length + 1;
    out.add('$path:$line  $lit');
  }
  return out;
}

void main() {
  test('aucun « rien ici » en texte nu au restaurant', () {
    final hits = <String>[];
    for (final f in Directory('lib/features/restaurant')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      hits.addAll(
          offenders(f.path.replaceAll(r'\', '/'), f.readAsStringSync()));
    }
    expect(hits, isEmpty,
        reason: 'écran entier → RestoEmptyState ; liste vide dans une '
            'section ou une feuille → RestoEmptyNote');
  });

  test('le garde-fou voit bien ce qu\'il doit voir', () {
    final filler = ' ' * 320;
    final src = [
      "if (list.isEmpty) return [Text('Aucune avance versée.')];",
      "if (events.isEmpty) Text(\n  'Rien à signaler ce mois-ci.',",
      "if (x.isEmpty) const Text('Aucun');",
      "if (y.isEmpty) const RestoEmptyNote('Aucune casse imputée.');",
      filler,
      "Text('Aucun motif n\\'est demandé : c\\'est un droit.');",
    ].join('\n');
    // Les deux premières seulement : puce, note et explication passent.
    expect(offenders('x', src), hasLength(2));
  });
}
