// Une seule façon de couper un montant : sur le symbole, dans la chaîne déjà
// produite par CurrencyFormatter — jamais recomposée à la main.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/restaurant/presentation/widgets/resto_amount_text.dart';

void main() {
  test('symbole après le nombre : « 2 500 » puis « FCFA »', () {
    final p = splitAmount('2 500 FCFA', 'FCFA')!;
    expect(p.before, '2 500 ');
    expect(p.symbol, 'FCFA');
    expect(p.after, '');
  });

  test('symbole avant le nombre : il reste devant', () {
    final p = splitAmount('\$12.50', '\$')!;
    expect(p.before, '');
    expect(p.after, '12.50');
  });

  test('rien ne se perd : les trois morceaux redonnent la chaîne', () {
    const s = '1 234 567 FCFA';
    final p = splitAmount(s, 'FCFA')!;
    expect('${p.before}${p.symbol}${p.after}', s);
  });

  test('symbole absent ou vide : pas de découpe', () {
    expect(splitAmount('2 500 €', 'FCFA'), isNull);
    expect(splitAmount('2 500', ''), isNull);
  });
}
