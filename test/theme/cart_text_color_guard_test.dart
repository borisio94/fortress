// GARDE-FOU — le panier restaurant écrit en variante TEXTE (lot « couleur
// jamais seule », 26/09/2026).
//
// `semantic_text_guard_test` ne parcourt que `lib/features/restaurant/` : la
// ligne du panier restaurant, logée dans `caisse/…/cart_widget.dart` (fichier
// partagé), lui échappait — son montant s'écrivait en orange de base, à
// 1,94:1 en clair. Ce garde-fou couvre ces deux classes-là : la ligne
// restaurant et le bandeau « Alerte marge » (les deux secteurs).
//
// Il lit TOUTE apparition d'une couleur de base, pas seulement celles posées
// dans un style : le défaut passait par une variable (`amountColor`). Une
// couleur de base n'y est admise que pour
//   • un fond teinté — suivie de `.withValues(` ;
//   • une icône — le constructeur le plus proche est `Icon(` ;
//   • une variable de fond — `final …Fill = …`.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Le corps de la classe [name] dans [src] (accolades appariées).
String classBody(String src, String name) {
  final at = src.indexOf('class $name ');
  expect(at, isNot(-1), reason: 'classe $name introuvable');
  var i = src.indexOf('{', at);
  var depth = 0;
  final start = i;
  for (; i < src.length; i++) {
    if (src[i] == '{') depth++;
    if (src[i] == '}' && --depth == 0) break;
  }
  return src.substring(start, i + 1);
}

final _base = RegExp(r'AppColors\.(?:warning|error|success|primary)\b|'
    r'\b(?:sem|semantic)\.(?:warning|danger|success|info|brand)\b(?!Text)');
final _ctor = RegExp(r'\b(Icon|Text|TextStyle|copyWith)\(');

/// Les apparitions de couleur de base NON admises dans [body].
List<String> offenders(String body) {
  final out = <String>[];
  for (final m in _base.allMatches(body)) {
    final after = body.substring(m.end);
    if (after.startsWith('.withValues(')) continue;
    final before = body.substring(0, m.start);
    final stmt = before.substring(before.lastIndexOf(';') + 1);
    if (RegExp(r'final\s+\w*Fill\s*=').hasMatch(stmt)) continue;
    final ctors = _ctor.allMatches(before).toList();
    if (ctors.isNotEmpty && ctors.last.group(1) == 'Icon') continue;
    final line = body.substring(before.lastIndexOf('\n') + 1,
        m.end + (after.contains('\n') ? after.indexOf('\n') : after.length));
    out.add(line.trim());
  }
  return out;
}

void main() {
  final src = File('lib/features/caisse/presentation/widgets/cart_widget.dart')
      .readAsStringSync();

  for (final name in ['_RestoCartItemRow', '_PriceAlertBanner']) {
    test('$name : aucune couleur de base sur du texte', () {
      expect(offenders(classBody(src, name)), isEmpty,
          reason: 'un texte s’écrit en variante texte (`warningText`, '
              '`brandText`…) — la base est pour les fonds et les icônes');
    });
  }

  test('contrôles : ce qui est refusé, ce qui est admis', () {
    // Refusés : dans un style, et par une variable qui finit sur du texte.
    expect(offenders('Text(x, style: s.copyWith(color: AppColors.warning))'),
        hasLength(1));
    expect(
        offenders('final amountColor = a ? AppColors.warning : '
            'AppColors.primary;'),
        hasLength(2));
    // Admis : fond teinté, icône, variable de fond, variante texte.
    expect(offenders('color: AppColors.warning.withValues(alpha: 0.1)'),
        isEmpty);
    expect(offenders('Icon(Icons.x, size: 16, color: AppColors.warning)'),
        isEmpty);
    expect(offenders('final amountFill = a ? AppColors.warning : '
            'AppColors.primary;'),
        isEmpty);
    expect(offenders('Text(x, style: s.copyWith(color: sem.warningText))'),
        isEmpty);
  });
}
