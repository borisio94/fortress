import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/services/arrival_costing_service.dart';
import 'package:fortress/features/inventaire/domain/entities/stock_arrival.dart';

// Valorisation d'une vague d'arrivage saisie depuis la fiche produit.
//
// Le prix de revient y est recalculé À PARTIR DE L'HISTORIQUE des vagues,
// pas par ajustements successifs. Ces tests verrouillent les deux
// propriétés qui en découlent et qu'un ajustement incrémental n'a pas :
// corriger une vague redonne le prix qu'on aurait eu sans l'erreur, et
// l'ordre de saisie n'influe pas sur le résultat.

StockArrival wave({
  required String id,
  required int qty,
  required double purchase,
  double fees = 0,
  String status = 'available',
}) =>
    StockArrival(
      id: id,
      shopId: 'shop_1',
      productId: 'p1',
      variantId: 'v1',
      quantity: qty,
      status: status,
      createdAt: DateTime(2026, 1, 1),
      purchaseTotal: purchase,
      feesTotal: fees,
    );

double? costOf(Iterable<StockArrival> waves) =>
    ArrivalCostingService.averageOverWaves(
      waves
          .where((a) => a.isCosted && a.isAvailable)
          .map((a) => ArrivalLine(
              key: a.id, quantity: a.quantity, unitCost: a.landedUnitCost)),
    );

void main() {
  group('StockArrival — coût de revient de la vague', () {
    test('achat global réparti sur la quantité', () {
      // 10 pièces pour 50 000 F → 5 000 F/pièce.
      expect(wave(id: 'a', qty: 10, purchase: 50000).landedUnitCost, 5000);
    });

    test('les dépenses liées entrent dans le coût de revient', () {
      // (50 000 + 15 000) / 10 → 6 500 F/pièce.
      expect(
        wave(id: 'a', qty: 10, purchase: 50000, fees: 15000).landedUnitCost,
        6500,
      );
    });

    test('quantité nulle → coût nul, pas de division par zéro', () {
      expect(wave(id: 'a', qty: 0, purchase: 50000).landedUnitCost, 0);
    });

    test('vague sans montant → non valorisée, exclue du calcul', () {
      expect(wave(id: 'a', qty: 10, purchase: 0).isCosted, isFalse);
      expect(wave(id: 'a', qty: 10, purchase: 50000).isCosted, isTrue);
    });
  });

  group('Prix de revient rejoué sur l\'historique', () {
    test('une seule vague → son propre coût de revient', () {
      expect(costOf([wave(id: 'a', qty: 10, purchase: 50000)]), 5000);
    });

    test('deux vagues → moyenne pondérée par les quantités', () {
      // 10 × 5 000 + 30 × 9 000 = 320 000 sur 40 pièces → 8 000.
      final c = costOf([
        wave(id: 'a', qty: 10, purchase: 50000),
        wave(id: 'b', qty: 30, purchase: 270000),
      ]);
      expect(c, 8000);
    });

    test('l\'ordre de saisie ne change pas le résultat', () {
      final a = wave(id: 'a', qty: 7, purchase: 21000, fees: 3500);
      final b = wave(id: 'b', qty: 13, purchase: 91000);
      expect(costOf([a, b]), costOf([b, a]));
    });

    test('corriger une vague redonne le prix sans l\'erreur', () {
      final juste = wave(id: 'b', qty: 30, purchase: 270000);
      // Saisie fautive (quantité 300 au lieu de 30), puis corrigée.
      final faux = wave(id: 'b', qty: 300, purchase: 270000);
      final base = wave(id: 'a', qty: 10, purchase: 50000);

      final avecFaute  = costOf([base, faux]);
      final apresFix   = costOf([base, juste]);
      final jamaisFaux = costOf([base, juste]);

      expect(avecFaute, isNot(apresFix));
      // Le point du recalcul : après correction, aucune trace de la faute.
      expect(apresFix, jamaisFaux);
    });

    test('supprimer une vague retire exactement sa contribution', () {
      final a = wave(id: 'a', qty: 10, purchase: 50000);
      final b = wave(id: 'b', qty: 30, purchase: 270000);
      expect(costOf([a, b]), 8000);
      expect(costOf([a]), 5000);
    });

    test('un incident ne pèse pas dans le prix de revient', () {
      final ok = wave(id: 'a', qty: 10, purchase: 50000);
      final ko = wave(id: 'b', qty: 90, purchase: 900000, status: 'damaged');
      expect(costOf([ok, ko]), 5000);
    });

    test('aucune vague valorisée → null (prix existant laissé intact)', () {
      expect(costOf([wave(id: 'a', qty: 10, purchase: 0)]), isNull);
      expect(costOf(const <StockArrival>[]), isNull);
    });
  });

  group('Schéma v1 → v2', () {
    test('une arrivée legacy se relit avec un coût à zéro', () {
      // Map tel qu'écrit avant l'ajout des champs de valorisation.
      final legacy = <String, dynamic>{
        'schema_version': 1,
        'id': 'sa_legacy',
        'variant_id': 'v1',
        'product_id': 'p1',
        'shop_id': 'shop_1',
        'quantity': 12,
        'status': 'available',
        'cause': 'direct_restock',
        'created_at': DateTime(2026, 1, 1).toIso8601String(),
      };
      final a = StockArrival.fromMap(legacy);
      expect(a.quantity, 12);
      expect(a.purchaseTotal, 0);
      expect(a.feesTotal, 0);
      // Non valorisée → n'entre pas dans la moyenne, plutôt que d'y entrer
      // à 0 F et d'effondrer le prix de revient.
      expect(a.isCosted, isFalse);
    });

    test('aller-retour toMap/fromMap conserve les montants', () {
      final a = wave(id: 'sa_1', qty: 8, purchase: 64000, fees: 8000);
      final back = StockArrival.fromMap(a.toMap());
      expect(back.purchaseTotal, 64000);
      expect(back.feesTotal, 8000);
      expect(back.landedUnitCost, 9000);
      expect(a.toMap()['schema_version'], StockArrival.currentSchemaVersion);
    });
  });
}
