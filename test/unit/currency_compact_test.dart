import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/utils/currency_formatter.dart';

/// Montant COMPACT — une seule règle (document de design § 14, 26/09/2026).
///
/// Avant : `CurrencyFormatter.compact` écrivait « 10.0k » au point décimal et
/// « -12500 » pour un négatif ; le graphique du restaurant avait sa propre
/// copie qui arrondissait à l'entier (« 2k » pour 1 500 — sur un pas de
/// 2 500, l'axe lisait « 3k, 5k, 8k »).
void main() {
  String c(double v) => CurrencyFormatter.compact(v);

  test('le tableau de la décision, valeur par valeur', () {
    expect(c(1500), '1,5k');
    expect(c(2500), '2,5k');
    expect(c(10000), '10k');
    expect(c(12500), '12,5k');
    expect(c(125000), '125k');
    expect(c(1250000), '1,3M');
    expect(c(-12500), '-12,5k');
  });

  test('une décimale seulement quand elle porte une information', () {
    expect(c(1000), '1k');
    expect(c(1050), '1,1k'); // 1,05 arrondi au dixième
    expect(c(99940), '99,9k');
    expect(c(100000), '100k');
    expect(c(2000000), '2M');
  });

  test('sous mille : l\'entier, sans décimale', () {
    expect(c(0), '0');
    expect(c(7), '7');
    expect(c(999), '999');
    expect(c(12.6), '13');
  });

  test('les seuils sont pris après arrondi — jamais « 1000k »', () {
    expect(c(999.6), '1k');
    expect(c(999500), '1M');
    expect(c(999400), '999k');
  });

  test('le signe : une perte reste une perte, mais pas de « -0 »', () {
    expect(c(-1500), '-1,5k');
    expect(c(-2500000), '-2,5M');
    expect(c(-0.4), '0');
  });
}
