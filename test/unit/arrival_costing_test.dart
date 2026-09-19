import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/services/arrival_costing_service.dart';
import 'package:fortress/features/inventaire/domain/entities/reception.dart';

// ═════════════════════════════════════════════════════════════════════════════
// Arrivage groupé — répartition des frais du lot PAR PIÈCE + absorption du
// coût de revient dans le prix d'achat du produit (moyenne pondérée).
// ═════════════════════════════════════════════════════════════════════════════

void main() {
  group('Répartition des frais par pièce', () {
    // Cas de référence : un lot de montres arrivé en un seul bloc.
    //   A → 3 × 5 000, B → 5 × 8 000, C → 2 × 3 000
    //   transport + douane : 15 000 pour 10 pièces → 1 500 / pièce
    test('exemple de référence — 10 pièces, 15 000 F de frais', () {
      final costing = ArrivalCostingService.compute(
        lines: const [
          ArrivalLine(key: 'A', quantity: 3, unitCost: 5000),
          ArrivalLine(key: 'B', quantity: 5, unitCost: 8000),
          ArrivalLine(key: 'C', quantity: 2, unitCost: 3000),
        ],
        feesTotal: 15000,
      );

      expect(costing.totalPieces, 10);
      expect(costing.feePerPiece, 1500);
      expect(costing.lineFor('A')!.landedUnitCost, 6500);
      expect(costing.lineFor('B')!.landedUnitCost, 9500);
      expect(costing.lineFor('C')!.landedUnitCost, 4500);
    });

    test('les totaux bouclent : marchandise + frais = total du lot', () {
      final costing = ArrivalCostingService.compute(
        lines: const [
          ArrivalLine(key: 'A', quantity: 3, unitCost: 5000),
          ArrivalLine(key: 'B', quantity: 5, unitCost: 8000),
          ArrivalLine(key: 'C', quantity: 2, unitCost: 3000),
        ],
        feesTotal: 15000,
      );

      expect(costing.goodsTotal, 61000);          // 15 000 + 40 000 + 6 000
      expect(costing.grandTotal, 76000);          // + 15 000 de frais
      // Aucun centime perdu dans la répartition.
      final sumLines = costing.lines
          .fold<double>(0, (s, l) => s + l.lineTotal);
      expect(sumLines, closeTo(costing.grandTotal, 0.000001));
      final sumFees = costing.lines
          .fold<double>(0, (s, l) => s + l.feeShare);
      expect(sumFees, closeTo(15000, 0.000001));
    });

    test('la valeur de la ligne ne change pas sa part de frais', () {
      // 1 pièce à 100 000 et 1 pièce à 1 000 supportent le même transport.
      final costing = ArrivalCostingService.compute(
        lines: const [
          ArrivalLine(key: 'cher',   quantity: 1, unitCost: 100000),
          ArrivalLine(key: 'modeste', quantity: 1, unitCost: 1000),
        ],
        feesTotal: 4000,
      );
      expect(costing.lineFor('cher')!.feeShare, 2000);
      expect(costing.lineFor('modeste')!.feeShare, 2000);
    });

    test('frais indivisibles → décimales conservées, rien n\'est perdu', () {
      final costing = ArrivalCostingService.compute(
        lines: const [
          ArrivalLine(key: 'A', quantity: 1, unitCost: 0),
          ArrivalLine(key: 'B', quantity: 2, unitCost: 0),
        ],
        feesTotal: 10000,
      );
      expect(costing.feePerPiece, closeTo(3333.333333, 0.0001));
      final sumFees = costing.lines
          .fold<double>(0, (s, l) => s + l.feeShare);
      expect(sumFees, closeTo(10000, 0.000001));
    });

    test('lot sans frais → coût de revient = prix d\'achat', () {
      final costing = ArrivalCostingService.compute(
        lines: const [ArrivalLine(key: 'A', quantity: 4, unitCost: 2500)],
      );
      expect(costing.feePerPiece, 0);
      expect(costing.lineFor('A')!.landedUnitCost, 2500);
    });

    test('lignes à quantité nulle ignorées — elles ne diluent pas les frais',
        () {
      final costing = ArrivalCostingService.compute(
        lines: const [
          ArrivalLine(key: 'recu',  quantity: 5, unitCost: 1000),
          ArrivalLine(key: 'absent', quantity: 0, unitCost: 9999),
        ],
        feesTotal: 5000,
      );
      expect(costing.totalPieces, 5);
      expect(costing.feePerPiece, 1000);
      expect(costing.lineFor('absent'), isNull);
    });

    test('lot vide → aucune division par zéro', () {
      final costing = ArrivalCostingService.compute(
        lines: const [], feesTotal: 12000);
      expect(costing.totalPieces, 0);
      expect(costing.feePerPiece, 0);
      expect(costing.lines, isEmpty);
    });
  });

  group('Moyenne pondérée du prix d\'achat', () {
    test('mélange le stock restant et le lot entrant', () {
      // 10 pièces à 6 000 + 10 pièces à 8 000 → 7 000
      final avg = ArrivalCostingService.weightedAverageUnitCost(
        currentQty: 10, currentUnitCost: 6000,
        incomingQty: 10, incomingUnitCost: 8000);
      expect(avg, 7000);
    });

    test('pondère par les quantités, pas à parts égales', () {
      // 2 pièces à 1 000 + 8 pièces à 6 000 → 5 000
      final avg = ArrivalCostingService.weightedAverageUnitCost(
        currentQty: 2, currentUnitCost: 1000,
        incomingQty: 8, incomingUnitCost: 6000);
      expect(avg, 5000);
    });

    test('stock à zéro → le coût entrant devient le coût du produit', () {
      final avg = ArrivalCostingService.weightedAverageUnitCost(
        currentQty: 0, currentUnitCost: 6000,
        incomingQty: 5, incomingUnitCost: 9000);
      expect(avg, 9000);
    });

    test('produit jamais valorisé → pas de moyenne avec un coût à 0', () {
      // Sans cette garde, 10 pièces "à 0" tireraient le coût vers le bas.
      final avg = ArrivalCostingService.weightedAverageUnitCost(
        currentQty: 10, currentUnitCost: 0,
        incomingQty: 5, incomingUnitCost: 9000);
      expect(avg, 9000);
    });

    test('rien ne rentre → coût inchangé', () {
      final avg = ArrivalCostingService.weightedAverageUnitCost(
        currentQty: 10, currentUnitCost: 6000,
        incomingQty: 0, incomingUnitCost: 9000);
      expect(avg, 6000);
    });

    test('stock négatif traité comme nul', () {
      final avg = ArrivalCostingService.weightedAverageUnitCost(
        currentQty: -3, currentUnitCost: 6000,
        incomingQty: 5, incomingUnitCost: 9000);
      expect(avg, 9000);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  // Frais seuls — la facture arrive après la marchandise, déjà en stock.
  // Le coût s'AJOUTE au prix d'achat existant : rien n'entre, donc rien ne
  // se moyenne. Confondre les deux sous-estimerait le coût de moitié.
  // ═══════════════════════════════════════════════════════════════════════
  group('Frais sur stock existant', () {
    test("la part de frais s'ajoute au prix d'achat", () {
      // 43 pièces déjà en rayon, 100 000 F de transport + douane.
      final costing = ArrivalCostingService.compute(
        lines: const [
          ArrivalLine(key: 'p1', quantity: 33),
          ArrivalLine(key: 'p2', quantity: 10),
        ],
        feesTotal: 100000,
      );
      expect(costing.totalPieces, 43);
      expect(costing.feePerPiece, closeTo(2325.581, 0.001));

      // Une montre achetée 7 000 revient désormais à 9 325,58.
      expect(
        ArrivalCostingService.surchargedUnitCost(
            currentUnitCost: 7000, feePerPiece: costing.feePerPiece),
        closeTo(9325.581, 0.001),
      );
    });

    test('addition, PAS moyenne pondérée', () {
      // Le piège : traiter ces frais comme un arrivage donnerait une
      // moyenne entre l'ancien coût et la part de frais — la moitié du
      // coût réel disparaîtrait sans un mot.
      const current = 7000.0, fee = 2000.0;
      final surcharged = ArrivalCostingService.surchargedUnitCost(
          currentUnitCost: current, feePerPiece: fee);
      final averaged = ArrivalCostingService.weightedAverageUnitCost(
          currentQty: 10, currentUnitCost: current,
          incomingQty: 10, incomingUnitCost: fee);
      expect(surcharged, 9000);
      expect(averaged, 4500);
      expect(surcharged, isNot(averaged));
    });

    test('produit jamais valorisé : les frais deviennent son coût', () {
      expect(
        ArrivalCostingService.surchargedUnitCost(
            currentUnitCost: 0, feePerPiece: 1500),
        1500,
      );
    });

    test('frais nuls ou absurdes → coût inchangé', () {
      // Un bon de frais sans montant ne doit rien écrire.
      expect(
        ArrivalCostingService.surchargedUnitCost(
            currentUnitCost: 7000, feePerPiece: 0),
        7000,
      );
      expect(
        ArrivalCostingService.surchargedUnitCost(
            currentUnitCost: 7000, feePerPiece: -500),
        7000,
      );
      expect(
        ArrivalCostingService.surchargedUnitCost(
            currentUnitCost: 7000, feePerPiece: double.nan),
        7000,
      );
    });

    test('le lot peut être plus grand que le stock restant', () {
      // 40 pièces reçues à l'origine, 33 encore en rayon : les frais se
      // répartissent sur le lot ENTIER, sinon les pièces restantes
      // porteraient la part des pièces déjà vendues.
      final costing = ArrivalCostingService.compute(
        lines: const [ArrivalLine(key: 'p1', quantity: 40)],
        feesTotal: 80000);
      expect(costing.feePerPiece, 2000);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  // Saisie par VARIANTE — un arrivage ne concerne presque jamais toutes les
  // déclinaisons d'un modèle. Chaque variante est une ligne autonome : sa
  // quantité, son prix, et surtout SA ligne de stock. Les confondre
  // reviendrait à verser le coût de la bleue sur l'argentée.
  // ═══════════════════════════════════════════════════════════════════════
  group('Arrivage par variante', () {
    test('deux variantes du meme modele restent des lignes distinctes', () {
      final costing = ArrivalCostingService.compute(
        lines: const [
          ArrivalLine(key: 'v_bleue',    quantity: 5, unitCost: 7000),
          ArrivalLine(key: 'v_argentee', quantity: 2, unitCost: 9000),
        ],
        feesTotal: 14000,      // 7 pieces -> 2 000 / piece
      );
      expect(costing.totalPieces, 7);
      expect(costing.feePerPiece, 2000);
      expect(costing.lineFor('v_bleue')!.landedUnitCost, 9000);
      expect(costing.lineFor('v_argentee')!.landedUnitCost, 11000);
    });

    test('une variante non recue ne supporte aucun frais', () {
      // Recevoir 5 bleues ne doit rien couter aux argentees restees chez
      // le fournisseur.
      final costing = ArrivalCostingService.compute(
        lines: const [
          ArrivalLine(key: 'v_bleue',    quantity: 5, unitCost: 7000),
          ArrivalLine(key: 'v_argentee', quantity: 0, unitCost: 9000),
        ],
        feesTotal: 10000,
      );
      expect(costing.totalPieces, 5);
      expect(costing.feePerPiece, 2000);
      expect(costing.lineFor('v_argentee'), isNull);
    });

    test('la ligne porte la variante visee, pas seulement le produit', () {
      // `variantId` decide de la ligne de stock creditee : sans lui, tout
      // atterrissait sur la variante principale.
      const item = ReceptionItem(
        id: 'ri_1', productId: 'p1', variantId: 'v_bleue',
        productName: 'Poedagar 928 — Bleue',
        expectedQty: 5, receivedQty: 5, unitCost: 7000,
      );
      final back = ReceptionItem.fromMap(item.toMap());
      expect(back.variantId, 'v_bleue');
      expect(back.productId, 'p1');
      expect(back.productName, contains('Bleue'));
    });
  });

  group('Reception — persistance et migration', () {
    Reception build() => Reception(
      id: 'rec_1', shopId: 'shop_1',
      status: ReceptionStatus.validated,
      items: const [
        ReceptionItem(id: 'ri_1', productId: 'p1', variantId: 'v1',
            productName: 'Montre A', expectedQty: 3, receivedQty: 3,
            unitCost: 5000, landedUnitCost: 6500),
      ],
      fees: const [
        ReceptionFee(label: 'Transport', amount: 10000),
        ReceptionFee(label: 'Douane', amount: 5000),
      ],
      createdAt: DateTime(2026, 8, 10),
    );

    test('aller-retour toMap/fromMap sans perte', () {
      final r = Reception.fromMap(build().toMap());
      expect(r.feesTotal, 15000);
      expect(r.fees.first.label, 'Transport');
      expect(r.items.first.unitCost, 5000);
      expect(r.items.first.landedUnitCost, 6500);
      expect(r.landedTotal, 19500);           // 3 × 6 500
      expect(r.hasCosting, isTrue);
    });

    test('bon v1 (avant valorisation) toujours lisible', () {
      final legacy = <String, dynamic>{
        'id': 'rec_old', 'shop_id': 'shop_1', 'status': 'validated',
        'items': [
          {'id': 'ri_old', 'product_id': 'p1', 'product_name': 'Ancien',
           'expected_qty': 2, 'received_qty': 2, 'status': 'available'},
        ],
        'created_at': '2026-01-01T00:00:00.000',
      };
      final r = Reception.fromMap(legacy);
      expect(r.fees, isEmpty);
      expect(r.feesTotal, 0);
      expect(r.items.first.unitCost, 0);
      expect(r.items.first.landedUnitCost, 0);
      expect(r.hasCosting, isFalse);          // aucun coût inventé
      expect(r.totalReceived, 2);             // le stock reste intact
    });

    test('migration idempotente — relire un map migré ne change rien', () {
      final once  = Reception.fromMap(build().toMap()).toMap();
      final twice = Reception.fromMap(once).toMap();
      expect(twice['fees'], once['fees']);
      expect(twice['items'], once['items']);
      expect(twice['schema_version'], Reception.currentSchemaVersion);
    });

    test('le drapeau frais seuls survit à la sérialisation', () {
      final r = Reception.fromMap(build().copyWith(costOnly: true).toMap());
      expect(r.costOnly, isTrue);
      expect(r.costingPieces, 3);
    });

    test('un bon v2 (avant les frais seuls) reste un vrai arrivage', () {
      // Non-régression : aucun bon existant ne doit se mettre à ne plus
      // faire entrer son stock.
      final v2 = build().toMap()
        ..remove('cost_only')
        ..['schema_version'] = 2;
      expect(Reception.fromMap(v2).costOnly, isFalse);
    });

    test('costingQty : attendu en brouillon, reçu dès la validation', () {
      const draft = ReceptionItem(id: 'a', productName: 'X', expectedQty: 5);
      expect(draft.costingQty, 5);
      expect(draft.copyWith(receivedQty: 3).costingQty, 3);
    });
  });
}
