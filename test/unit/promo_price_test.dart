import 'package:flutter_test/flutter_test.dart';

import 'package:fortress/features/inventaire/domain/entities/product.dart';

/// ARG-4 — la promotion affichée doit être la promotion facturée.
///
/// La règle vivait en privé dans `product_grid_card.dart`, qui s'en servait
/// pour barrer un prix ; le panier ne la connaissait pas et facturait
/// `priceSellPos`. Le client voyait une remise et payait le plein tarif.
///
/// Ces cas couvrent `ProductVariant.isPromoActive` / `effectiveSellPrice`,
/// désormais seule source de vérité pour l'affichage ET la facturation.
void main() {
  ProductVariant variant({
    required double priceSellPos,
    bool promoEnabled = true,
    double? promoPrice,
    DateTime? promoStart,
    DateTime? promoEnd,
  }) =>
      ProductVariant(
        name: 'Taille L',
        priceSellPos: priceSellPos,
        promoEnabled: promoEnabled,
        promoPrice: promoPrice,
        promoStart: promoStart,
        promoEnd: promoEnd,
      );

  group('ProductVariant — promotion active', () {
    test('promo active DANS la fenêtre → le prix promo est appliqué', () {
      final now = DateTime.now();
      final v = variant(
        priceSellPos: 10000,
        promoPrice: 7500,
        promoStart: now.subtract(const Duration(days: 1)),
        promoEnd: now.add(const Duration(days: 1)),
      );
      expect(v.isPromoActive, isTrue);
      expect(v.effectiveSellPrice, 7500);
    });

    test('sans bornes de dates, la promo s\'applique', () {
      final v = variant(priceSellPos: 10000, promoPrice: 9000);
      expect(v.isPromoActive, isTrue);
      expect(v.effectiveSellPrice, 9000);
    });
  });

  group('ProductVariant — promotion inopérante', () {
    test('promo HORS fenêtre (déjà terminée) → prix normal', () {
      final now = DateTime.now();
      final v = variant(
        priceSellPos: 10000,
        promoPrice: 7500,
        promoStart: now.subtract(const Duration(days: 10)),
        promoEnd: now.subtract(const Duration(days: 2)),
      );
      expect(v.isPromoActive, isFalse);
      expect(v.effectiveSellPrice, 10000);
    });

    test('promo HORS fenêtre (pas encore commencée) → prix normal', () {
      final now = DateTime.now();
      final v = variant(
        priceSellPos: 10000,
        promoPrice: 7500,
        promoStart: now.add(const Duration(days: 2)),
      );
      expect(v.isPromoActive, isFalse);
      expect(v.effectiveSellPrice, 10000);
    });

    test('promoEnabled = false → prix normal, même avec un prix promo', () {
      final v = variant(
        priceSellPos: 10000,
        promoEnabled: false,
        promoPrice: 7500,
      );
      expect(v.isPromoActive, isFalse);
      expect(v.effectiveSellPrice, 10000);
    });

    test('promoPrice = null → prix normal', () {
      final v = variant(priceSellPos: 10000, promoPrice: null);
      expect(v.isPromoActive, isFalse);
      expect(v.effectiveSellPrice, 10000);
    });

    test('promoPrice >= priceSellPos → prix normal (une promo plus chère '
        'n\'en est pas une)', () {
      final egal = variant(priceSellPos: 10000, promoPrice: 10000);
      expect(egal.isPromoActive, isFalse);
      expect(egal.effectiveSellPrice, 10000);

      final plusCher = variant(priceSellPos: 10000, promoPrice: 12000);
      expect(plusCher.isPromoActive, isFalse);
      expect(plusCher.effectiveSellPrice, 10000);
    });
  });
}
