// LOT 1B — les fonds de marque sous du BLANC passent par `AppColors.primaryFill`
// (26/09/2026).
//
// En sombre, `AppColors.primary` / `colorScheme.primary` sont la variante
// TEXTE de la marque, claire : le blanc n'y tenait que 2,54 à 3,25:1 sur les
// huit palettes. 124 fonds peints à la main ont été repointés ; ce garde-fou
// empêche le motif le plus fréquent (99 cas sur 144) de revenir.
//
// CE QU'IL LIT : chaque `styleFrom(...)` de `lib/` qui peint la primaire en
// `backgroundColor`. Il est accepté SEULEMENT si le libellé est déclaré en
// `onPrimary` (texte foncé en sombre, qui tient sur la primaire claire) ;
// sinon — blanc explicite, ou libellé laissé au thème, qui est blanc — il doit
// passer à `AppColors.primaryFill`.
//
// Il ne lit PAS les `BoxDecoration` / `Material` peints à la main : leur
// contenu est un enfant quelconque, qu'une expression régulière ne sait pas
// suivre. Ceux-là ont été vérifiés un par un au lot 1b.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final _primaryBg = RegExp(
    r'backgroundColor:\s*(?:AppColors|cs|colorScheme|scheme|'
    r'Theme\.of\(\w+\)\.colorScheme|theme\.colorScheme)'
    r'\.primary\b(?!Fill|Container|Fixed|Light|Dark|Surface)(?!\s*\.withValues)');

/// Position de la parenthèse OUVRANTE de l'appel qui enveloppe [at].
int _enclosingOpen(String src, int at) {
  var depth = 0;
  var k = at;
  while (k > 0) {
    final c = src[k];
    if (c == ')') {
      depth++;
    } else if (c == '(') {
      if (depth == 0) break;
      depth--;
    }
    k--;
  }
  return k;
}

/// Texte des arguments de l'appel qui enveloppe [at].
String _callArgs(String src, int at) {
  var depth = 0;
  var k = at;
  while (k > 0) {
    final c = src[k];
    if (c == ')') {
      depth++;
    } else if (c == '(') {
      if (depth == 0) break;
      depth--;
    }
    k--;
  }
  final start = k;
  depth = 0;
  var j = start;
  while (j < src.length) {
    final c = src[j];
    if (c == '(') {
      depth++;
    } else if (c == ')') {
      depth--;
      if (depth == 0) break;
    }
    j++;
  }
  return src.substring(start, j + 1);
}

List<String> offenders(Map<String, String> sources) {
  final out = <String>[];
  sources.forEach((path, src) {
    for (final m in _primaryBg.allMatches(src)) {
      // Seulement si l'appel qui enveloppe le `backgroundColor` EST un
      // `styleFrom` (pas un CircleAvatar ou un FloatingActionButton voisin).
      final open = _enclosingOpen(src, m.start);
      if (open < 9 || src.substring(open - 9, open) != 'styleFrom') continue;
      final head = src.substring(0, m.start);
      final args = _callArgs(src, m.start);
      if (RegExp(r'foregroundColor:\s*[\w\.\(\)]*onPrimary\b').hasMatch(args)) {
        continue;
      }
      final line = '\n'.allMatches(head).length + 1;
      out.add('${path.replaceAll('\\', '/')}:$line');
    }
  });
  return out;
}

// ─── FONDS PEINTS À LA MAIN (nettoyage de forme, 26/09/2026) ───────────────
//
// Le lot 1b a laissé passer 17 fonds écrits en TERNAIRE
// (`color: selected ? cs.primary : …`) : la règle ci-dessus ne lisait que les
// `styleFrom`. Celle-ci lit le `color:` d'une décoration, d'un `Container`,
// d'un `Material`… dès que la primaire y figure, ternaire compris, et le
// signale si du blanc est posé dans les 25 lignes qui suivent. Une couleur
// passée par une variable lui échappe (la priorité « normal » des tickets en
// était un cas, corrigé à la main).

final _paintedPrimary = RegExp(
    r'\b(?:color|backgroundColor):[^,;\n]*?(?:AppColors|cs|colorScheme|scheme|'
    r'Theme\.of\(\w+\)\.colorScheme|theme\.colorScheme)'
    r'\.primary\b(?!Fill|Container|Fixed|Light|Dark|Surface)(?!\s*\.withValues)');
const _fillCallees = [
  'BoxDecoration', 'Container', 'AnimatedContainer', 'Material', 'Ink',
  'CircleAvatar', 'ColoredBox', 'DecoratedBox',
];
final _whiteContent =
    RegExp(r'Colors\.white\b(?!\.withValues\(alpha:\s*0\.[0-4])');

List<String> paintedOffenders(Map<String, String> sources) {
  final out = <String>[];
  sources.forEach((path, src) {
    for (final m in _paintedPrimary.allMatches(src)) {
      final open = _enclosingOpen(src, m.start);
      final head = src.substring(open < 40 ? 0 : open - 40, open);
      if (!_fillCallees.any((c) => head.endsWith(c))) continue;
      final lineStart = '\n'.allMatches(src.substring(0, m.start)).length;
      final lines = src.split('\n');
      final window = lines
          .sublist(lineStart, (lineStart + 25).clamp(0, lines.length))
          .join('\n');
      if (!_whiteContent.hasMatch(window)) continue;
      out.add('${path.replaceAll(r'\', '/')}:${lineStart + 1}');
    }
  });
  return out;
}

Map<String, String> _libSources() => {
      for (final f in Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .where((f) =>
              !f.path.replaceAll(r'\', '/').contains('lib/core/theme/')))
        f.path: f.readAsStringSync(),
    };

void main() {
  test('aucun fond peint en primaire sous du blanc (ternaires compris)', () {
    expect(paintedOffenders(_libSources()), isEmpty,
        reason: 'un fond de marque sous du blanc s\'écrit '
            'AppColors.primaryFill, aussi dans un ternaire');
  });

  test('la règle des fonds peints voit bien ce qu\'elle doit voir', () {
    const ternaire = '''
      Container(
        decoration: BoxDecoration(
          color: selected ? cs.primary : null),
        child: Text('Table 1', style: TextStyle(color: Colors.white)))''';
    const fill = '''
      Container(
        decoration: BoxDecoration(
          color: selected ? AppColors.primaryFill : null),
        child: Text('Table 1', style: TextStyle(color: Colors.white)))''';
    const onPrimary = '''
      Container(
        decoration: BoxDecoration(color: cs.primary),
        child: Text('OK', style: TextStyle(color: cs.onPrimary)))''';
    const teinte = '''
      Container(
        decoration: BoxDecoration(
          color: cs.primary.withValues(alpha: 0.12)),
        child: Icon(Icons.x, color: Colors.white))''';
    expect(paintedOffenders({'a': ternaire}), hasLength(1));
    expect(paintedOffenders({'b': fill}), isEmpty);
    expect(paintedOffenders({'c': onPrimary}), isEmpty);
    expect(paintedOffenders({'d': teinte}), isEmpty);
  });

  test('aucun bouton ne peint la primaire sous un libellé blanc', () {
    final sources = _libSources();
    expect(offenders(sources), isEmpty,
        reason: 'un fond de marque sous du blanc s\'écrit '
            'AppColors.primaryFill ; la primaire ne reste en fond que sous '
            'un libellé onPrimary');
  });

  test('le garde-fou voit bien ce qu\'il doit voir', () {
    const blanc = '''
      ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white)''';
    const theme = '''
      FilledButton.styleFrom(backgroundColor: AppColors.primary)''';
    const onPrimary = '''
      ElevatedButton.styleFrom(
          backgroundColor: cs.primary, foregroundColor: cs.onPrimary)''';
    const fill = '''
      ElevatedButton.styleFrom(
          backgroundColor: AppColors.primaryFill,
          foregroundColor: Colors.white)''';
    expect(offenders({'a': blanc}), hasLength(1));
    expect(offenders({'b': theme}), hasLength(1));
    expect(offenders({'c': onPrimary}), isEmpty);
    expect(offenders({'d': fill}), isEmpty);
    // Un autre appel après un styleFrom n'est pas un styleFrom.
    expect(offenders({'e': '$theme; CircleAvatar(backgroundColor: cs.primary)'}),
        hasLength(1));
  });
}
