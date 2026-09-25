import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/i18n/app_localizations.dart';
import 'package:fortress/shared/navigation/page_titles.dart';

/// Lot Shell (25/09/2026) — les sous-pages du restaurant ont un titre écrit.
///
/// Sans lui, le shell dérivait le titre du dernier segment d'URL : « Cloture »,
/// « Reconcile », « Setup » — de l'anglais et des accents manquants, affichés
/// à l'utilisateur. Chaque titre reprend celui que la page se donne elle-même.
void main() {
  const l = AppLocalizations(Locale('fr'));
  const shop = 'shop-1';

  String? title(String path) =>
      titleForLocation(location: '/shop/$shop$path', shopId: shop, l: l);

  test('les sous-pages du restaurant ont leur titre, en français', () {
    expect(title('/restaurant/caisse/cloture'), 'Clôture de caisse');
    expect(title('/restaurant/inventory/reconcile'), 'Inventaire');
    expect(title('/restaurant/setup'), 'Configuration');
    expect(title('/restaurant/pointage'), 'Badgeuse');
  });

  test("l'addition d'une table, quel que soit son identifiant", () {
    expect(title('/restaurant/addition/3f6c2a90-1b7e-4c1d-9a55-2e0f7b8c4d11'),
        'Addition');
  });

  test('aucun titre restaurant ne retombe sur le repli de l\'URL', () {
    for (final path in [
      '/restaurant/caisse/cloture',
      '/restaurant/inventory/reconcile',
      '/restaurant/setup',
      '/restaurant/pointage',
      '/restaurant/addition/42',
    ]) {
      expect(title(path), isNotNull, reason: path);
    }
  });
}
