// GARDE-FOU — les couleurs d'état de BASE ne reviennent pas en texte au
// restaurant (lot « couleurs sémantiques en texte », 26/09/2026).
//
// « Le token suit son fond » : `danger`, `warning`, `success` et `info` sont
// faits pour une icône, un trait ou un fond ; en texte sur une surface claire
// ils échouent (`warning` 2,01:1, `success` 2,38, `info` 3,45, `danger` 3,53 au
// pire de la carte, du fond et du verre). Le lot en a corrigé ≈ 120. Sans ce
// test, la règle reviendrait à zéro en trois sessions.
//
// CE QU'IL LIT : chaque `color:` (ou `foregroundColor:` de bouton) posé
// DIRECTEMENT dans un `TextStyle(...)`, un `.copyWith(...)` ou un
// `styleFrom(...)` des fichiers de `lib/features/restaurant/`. Une couleur
// passée par une variable lui échappe : c'est à `AppSemanticColors.textFor`
// et `restoTextOn` de la rendre juste à la source.
//
// LA PRIMAIRE est lue aussi, SANS exception depuis le lot 1 clair
// (26/09/2026) : un texte de marque s'écrit en `semantic.brandText`, la seule
// valeur tenue à 4,5:1 sur ses propres teintes dans les DEUX modes
// (`colorScheme.primary` ne l'est pas en sombre : 3,68–4,58 sur sept
// palettes). Une information s'écrit en `onSurface`.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final _base = RegExp(
    r'(?:foregroundColor|color):\s*(?:\w+\.|Theme\.of\(\w+\)\.)?semantic\.'
    r'(danger|warning|success|info)\b(?!Text|Surface)'
    r'|(?:foregroundColor|color):\s*sem\.(danger|warning|success|info)\b(?!Text|Surface)');
final _primary = RegExp(
    r'(?:foregroundColor|color):\s*(?:cs|(?:Theme\.of\(\w+\)|theme)\.colorScheme)'
    r'\.primary\b(?!Container|Fixed)'
    r'|(?:foregroundColor|color):\s*AppColors\.primary\b(?!Surface|Light|Dark)');

/// Nom de l'appel qui ENVELOPPE la position [at] : on remonte jusqu'à la
/// parenthèse ouvrante non refermée.
String _enclosingCall(String src, int at) {
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
  final head = src.substring(k - 60 < 0 ? 0 : k - 60, k + 1);
  final m = RegExp(r'([A-Za-z_\.]+)\s*\($').firstMatch(head);
  return m?.group(1) ?? '';
}

bool _isTextStyle(String callee) =>
    callee.endsWith('copyWith') ||
    callee.endsWith('TextStyle') ||
    callee.endsWith('styleFrom');

void main() {
  final files = Directory('lib/features/restaurant')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  List<String> offenders(RegExp pattern) {
    final out = <String>[];
    for (final f in files) {
      final src = f.readAsStringSync();
      for (final m in pattern.allMatches(src)) {
        final callee = _enclosingCall(src, m.start);
        if (!_isTextStyle(callee)) continue;
        // `styleFrom` : seul `foregroundColor` écrit le libellé.
        if (callee.endsWith('styleFrom') &&
            !m.group(0)!.startsWith('foregroundColor')) {
          continue;
        }
        final line = '\n'.allMatches(src.substring(0, m.start)).length + 1;
        out.add('${f.path.replaceAll('\\', '/')}:$line  ${m.group(0)}');
      }
    }
    return out;
  }

  test('aucun token d\'état de BASE en couleur de texte', () {
    expect(offenders(_base), isEmpty,
        reason: 'utiliser la variante *Text (dangerText, warningText, '
            'successText) ; `info` s\'écrit en textSecondary (§ 16)');
  });

  test('aucune primaire en couleur de texte : brandText ou onSurface', () {
    expect(offenders(_primary), isEmpty,
        reason: 'un lien ou un bouton de marque s\'écrit en '
            'semantic.brandText (tenu sur ses teintes dans les deux modes) ; '
            'une information en onSurface');
  });

  test('le garde-fou voit bien ce qu\'il doit voir', () {
    // Sans ce contrôle, un motif cassé rendrait les deux tests verts pour de
    // mauvaises raisons.
    const sample = '''
      Text('x', style: AppTextStyles.micro.copyWith(color: sem.warning));
      Icon(Icons.x, color: sem.warning);
      Text('y', style: TextStyle(color: sem.dangerText));
    ''';
    final hits = _base.allMatches(sample).where(
        (m) => _isTextStyle(_enclosingCall(sample, m.start)));
    expect(hits, hasLength(1));
  });
}
