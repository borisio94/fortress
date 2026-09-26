// Le volet panier du Menu (`cartPaneLayout`) : sa largeur lit l'écran, sa
// décision de recouvrir la carte lit le corps de page (26/09/2026).

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/restaurant/domain/cart_pane_layout.dart';
import 'package:fortress/features/restaurant/domain/menu_grid_geometry.dart';
import 'package:fortress/shared/providers/cart_pane_provider.dart';

/// Barre latérale du shell ordinateur, dépliée et repliée.
const _sidebarOpen = 247.0;
const _sidebarClosed = 76.0;

CartPaneLayout at(double screen, {double sidebar = 0}) =>
    cartPaneLayout(screenWidth: screen, bodyWidth: screen - sidebar);

void main() {
  test('le plancher de la carte vient du seuil 720 : ils ne divergent pas',
      () {
    expect(kMenuBesideCartPaneMin,
        kCartPaneFullWidthBelow - kCartPaneMinWidth - kCartPaneGap);
  });

  group('shell mobile (corps = écran) : la bascule reste à 720', () {
    test('719 : le volet recouvre la carte, sur toute la largeur', () {
      expect(at(719), (coversMenu: true, width: 719.0));
    });

    test('720 : côte à côte, volet de 320', () {
      expect(at(720), (coversMenu: false, width: 320.0));
    });

    test('800 : côte à côte, volet de 320', () {
      expect(at(800), (coversMenu: false, width: 320.0));
    });
  });

  group('barre latérale DÉPLIÉE', () {
    test('900 : recouvre (la carte aurait 323 px, 138 par tuile)', () {
      expect(at(900, sidebar: _sidebarOpen),
          (coversMenu: true, width: 653.0));
    });

    test('970 : recouvre encore (389,7 px à côté ; bascule à 970,5)', () {
      expect(at(970, sidebar: _sidebarOpen).coversMenu, isTrue);
    });

    test('971 : côte à côte, et la carte garde ses 390 px', () {
      final l = at(971, sidebar: _sidebarOpen);
      expect(l.coversMenu, isFalse);
      expect(971 - _sidebarOpen - l.width - kCartPaneGap,
          greaterThanOrEqualTo(kMenuBesideCartPaneMin));
    });

    test('1 280 : volet inchangé (420), la carte à 2 colonnes', () {
      final l = at(1280, sidebar: _sidebarOpen);
      expect(l, (coversMenu: false, width: 420.0));
      expect(menuGridLayout(1280 - _sidebarOpen - 420 - kCartPaneGap - 32)
          .cols, 2);
    });
  });

  test('barre REPLIÉE, 900 : côte à côte, comme avant', () {
    expect(at(900, sidebar: _sidebarClosed),
        (coversMenu: false, width: 320.0));
  });

  test('côte à côte, les tuiles ne tombent jamais sous 172 px', () {
    for (var w = 700.0; w <= 1600; w += 10) {
      for (final side in [0.0, _sidebarClosed, _sidebarOpen]) {
        if (w >= 900 && side == 0) continue; // pas de shell sans barre
        if (w < 900 && side > 0) continue; // pas de barre en mobile
        final l = at(w, sidebar: side);
        if (l.coversMenu) continue;
        final g = menuGridLayout(w - side - l.width - kCartPaneGap - 32);
        expect(g.tileWidth, greaterThanOrEqualTo(172),
            reason: 'écran $w, barre $side');
      }
    }
  });
}
