// La caisse e-commerce (`caisseCartInline`) : panier intégré ou onglets,
// décidé sur le corps de page (26/09/2026).

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/caisse/domain/caisse_layout.dart';

/// Barre latérale du shell ordinateur, dépliée et repliée.
const _sidebarOpen = 247.0;
const _sidebarClosed = 76.0;

/// La règle de colonnes de la grille produits de la caisse
/// (`PosProductPanel`, `product_grid_widget.dart`) : 2 colonnes sous 600 px,
/// sinon une par 180 px ; marges 12, écarts 16. RECOPIÉE ici : si la grille
/// change, ce test doit être relu.
double tileWidth(double panel) {
  final cols = panel < 600 ? 2 : (panel ~/ 180).clamp(2, 8);
  return (panel - 24 - 16 * (cols - 1)) / cols;
}

bool at(double screen, {double sidebar = 0}) =>
    caisseCartInline(screen - sidebar);

void main() {
  group('shell mobile (corps = écran) : la bascule reste à 800 / 801', () {
    test('800 : onglets, comme avant (`écran > 800`)', () {
      expect(at(800), isFalse);
    });
    test('801 : panier intégré', () {
      expect(at(801), isTrue);
    });
    test('899 : panier intégré', () {
      expect(at(899), isTrue);
    });
  });

  group('barre latérale DÉPLIÉE (défaut de l’e-commerce)', () {
    test('900 : onglets (les produits auraient 272 px, 116 par tuile)', () {
      expect(at(900, sidebar: _sidebarOpen), isFalse);
    });
    test('1 047 : onglets encore', () {
      expect(at(1047, sidebar: _sidebarOpen), isFalse);
    });
    test('1 048 : panier intégré', () {
      expect(at(1048, sidebar: _sidebarOpen), isTrue);
    });
  });

  test('barre REPLIÉE, 900 : panier intégré', () {
    expect(at(900, sidebar: _sidebarClosed), isTrue);
  });

  // Au-delà de 600 px de produits, la grille passe à 3 colonnes et plus : ses
  // tuiles suivent alors SA règle (une par 180 px, parfois 162 sur grand
  // écran), panier ou pas. Ce que le panier resserre, c'est le régime à
  // 2 colonnes : c'est lui que ce lot garde au-dessus de 190.
  test('panier intégré, à 2 colonnes, les tuiles ne tombent jamais sous '
      '190 px', () {
    for (var w = 700.0; w <= 1920; w += 1) {
      for (final side in [0.0, _sidebarClosed, _sidebarOpen]) {
        if (w >= 900 && side == 0) continue; // pas de shell sans barre
        if (w < 900 && side > 0) continue; // pas de barre en mobile
        if (!at(w, sidebar: side)) continue;
        final panel = w - side - kCaisseCartWidth - kCaisseCartDivider;
        if (panel >= 600) continue;
        expect(tileWidth(panel), greaterThanOrEqualTo(190),
            reason: 'écran $w, barre $side');
      }
    }
  });
}
