import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/caisse/domain/entities/sale_item.dart';
import 'package:fortress/features/restaurant/domain/order_tile.dart';

SaleItem _item(String nom, int qte) => SaleItem(
      productId: nom.toLowerCase(),
      productName: nom,
      unitPrice: 1000,
      quantity: qte,
    );

void main() {
  group('orderContentsLine — la forme longue, inchangée', () {
    test('une commande vide le dit', () {
      expect(orderContentsLine(const []), 'Aucun article');
    });

    test('une quantité de 1 ne porte pas de préfixe', () {
      expect(orderContentsLine([_item('Poulet DG', 1)]), 'Poulet DG');
    });

    test('au-delà de 1, la quantité précède le nom', () {
      expect(orderContentsLine([_item('Ndolè', 2)]), '2× Ndolè');
    });

    test('les plats se suivent, séparés par une virgule', () {
      expect(
        orderContentsLine([_item('Ndolè', 2), _item('Jus', 1), _item('Éru', 3)]),
        '2× Ndolè, Jus, 3× Éru',
      );
    });
  });

  group('orderContentsShort — la forme de la tuile', () {
    test('une commande vide le dit aussi', () {
      expect(orderContentsShort(const []), 'Aucun article');
    });

    test('un seul plat ne porte AUCUN suffixe', () {
      expect(orderContentsShort([_item('Poulet DG', 1)]), 'Poulet DG');
    });

    test('le préfixe de quantité survit sur la tête', () {
      expect(orderContentsShort([_item('Ndolè', 2)]), '2× Ndolè');
    });

    test('deux plats : « autre » au SINGULIER', () {
      expect(
        orderContentsShort([_item('Poulet DG', 1), _item('Jus', 1)]),
        'Poulet DG + 1 autre',
      );
    });

    test('cinq plats : la tête et le compte des quatre autres', () {
      expect(
        orderContentsShort([
          _item('Poulet DG', 1),
          _item('Jus', 1),
          _item('Ndolè', 2),
          _item('Éru', 1),
          _item('Beignets', 4),
        ]),
        'Poulet DG + 4 autres',
      );
    });

    test('le compte est celui des LIGNES, jamais des quantités', () {
      // Quatre plats dont un en quantité 7 : la tuile annonce trois autres
      // plats, pas dix articles.
      expect(
        orderContentsShort([
          _item('Ndolè', 7),
          _item('Jus', 1),
          _item('Éru', 1),
          _item('Beignets', 1),
        ]),
        '7× Ndolè + 3 autres',
      );
    });
  });

  group('orderGridColumns — les colonnes se déduisent du plancher', () {
    test('le cas qui a motivé le lot : 1046 px donnent TROIS colonnes', () {
      expect(orderGridColumns(1046), 3);
      // Et la tuile repasse largement au-dessus du plancher.
      expect((1046 - 10 * 2) / 3, greaterThan(kOrderTileMin));
    });

    test('la tuile ne descend JAMAIS sous le plancher', () {
      for (var w = 120.0; w <= 2400; w += 7) {
        final cols = orderGridColumns(w);
        if (cols == 1) continue; // une colonne étirée est le repli assumé
        final tile = (w - 10 * (cols - 1)) / cols;
        expect(tile, greaterThanOrEqualTo(kOrderTileMin),
            reason: 'à $w px, $cols colonnes donnent une tuile de $tile');
      }
    });

    test('la progression suit le plancher, pas des seuils d\'écran', () {
      expect(orderGridColumns(400), 1);
      expect(orderGridColumns(620), 2);
      expect(orderGridColumns(800), 2);
      expect(orderGridColumns(930), 3);
      expect(orderGridColumns(1270), 4);
    });

    test('QUATRE COLONNES AU PLUS — la borne arbitraire est tenue', () {
      // C'est le seul obstacle à cinq colonnes : la formule les calculerait.
      expect(orderGridColumns(1600), kOrderGridMaxColumns);
      expect(orderGridColumns(3000), kOrderGridMaxColumns);
      // Preuve que la borne MORD : sans elle, 1600 px donneraient cinq.
      expect((1600 + 10) ~/ (kOrderTileMin + 10), 5);
    });

    test('une largeur nulle ou négative ne casse pas', () {
      expect(orderGridColumns(0), 1);
      expect(orderGridColumns(-40), 1);
    });
  });
}
