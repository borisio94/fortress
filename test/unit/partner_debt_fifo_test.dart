import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/services/partner_ledger_service.dart';
import 'package:fortress/features/parametres/domain/entities/partner_ledger_entry.dart';

/// Imputation FIFO des dettes de la boutique envers un partenaire
/// (`PartnerLedgerService.computeOrderDebts`) — corrige la « dette fantôme »
/// qui réapparaissait sur une commande déjà réglée dès qu'un nouveau frais
/// faisait repasser le solde du partenaire sous zéro.
void main() {
  var seq = 0;
  final t0 = DateTime(2026, 7, 1, 8);

  PartnerLedgerEntry e(
    PartnerLedgerEntryType type,
    double amount, {
    String? order,
    int minute = 0,
    String partner = 'p1',
    DateTime? deletedAt,
  }) =>
      PartnerLedgerEntry(
        id: 'e${seq++}',
        shopId: 's1',
        partnerLocationId: partner,
        orderId: order,
        type: type,
        amount: amount,
        createdAt: t0.add(Duration(minutes: minute)),
        deletedAt: deletedAt,
      );

  const fee = PartnerLedgerEntryType.deliveryOwed;
  const charge = PartnerLedgerEntryType.partnerCharge;
  const remit = PartnerLedgerEntryType.remittance;
  const sale = PartnerLedgerEntryType.saleCollected;
  const advance = PartnerLedgerEntryType.advance;

  Map<String, double> owed(List<PartnerLedgerEntry> entries, Set<String> ids) =>
      PartnerLedgerService.computeOrderDebts(entries, ids)
          .map((k, v) => MapEntry(k, v.amount));

  test('frais réglé puis nouveau frais : seul le nouveau apparaît', () {
    final entries = [
      e(fee, -1500, order: 'A', minute: 1),
      e(remit, 1500, minute: 2), // « Régler le partenaire », global
      e(fee, -1000, order: 'B', minute: 3),
    ];
    final r = PartnerLedgerService.computeOrderDebts(entries, {'A', 'B'});
    expect(r['A']!.amount, 0);
    expect(r['A']!.isOutstanding, isFalse);
    expect(r['B']!.amount, 1000);
    expect(r['B']!.isOutstanding, isTrue);
  });

  test('règlement partiel : les plus anciens frais sont éteints d\'abord', () {
    final base = [
      e(fee, -1500, order: 'A', minute: 1),
      e(fee, -1000, order: 'B', minute: 2),
    ];
    expect(owed([...base, e(remit, 1000, minute: 3)], {'A', 'B'}),
        {'A': 500, 'B': 1000});
    expect(owed([...base, e(remit, 2000, minute: 3)], {'A', 'B'}),
        {'A': 0, 'B': 500});
  });

  test('partenaire qui a encaissé : ses frais se compensent dans la commande',
      () {
    final r = owed([
      e(sale, 10000, order: 'C', minute: 1),
      e(fee, -1500, order: 'C', minute: 1),
    ], {'C'});
    expect(r, {'C': 0});
  });

  test('ventes non reversées d\'une autre commande : couvrent les frais (2a)',
      () {
    final entries = [
      e(fee, -1000, order: 'D', minute: 1), // livrée, payée à la boutique
      e(sale, 5000, order: 'C', minute: 2), // encaissée par le partenaire
    ];
    expect(owed(entries, {'D'}), {'D': 0});
    // Une fois la vente de C reversée, plus rien ne couvre D.
    expect(owed([...entries, e(remit, -5000, order: 'C', minute: 3)], {'D'}),
        {'D': 1000});
  });

  test('avance de la boutique : couvre les frais (1a)', () {
    expect(owed([
      e(fee, -1500, order: 'A', minute: 1),
      e(advance, 2000, minute: 2),
    ], {'A'}), {'A': 0});
  });

  test('charge sans commande plus ancienne : consomme le crédit en premier',
      () {
    expect(owed([
      e(charge, -500, minute: 1),
      e(fee, -1500, order: 'A', minute: 2),
      e(remit, 1500, minute: 3),
    ], {'A'}), {'A': 500});
  });

  test('écriture supprimée : ignorée', () {
    expect(owed([
      e(fee, -1500, order: 'A', minute: 1),
      e(remit, 1500, minute: 2, deletedAt: t0),
    ], {'A'}), {'A': 1500});
  });

  test('partenaires isolés : le crédit de l\'un ne couvre pas l\'autre', () {
    expect(owed([
      e(fee, -1500, order: 'A', minute: 1, partner: 'p1'),
      e(remit, 5000, minute: 2, partner: 'p2'),
    ], {'A'}), {'A': 1500});
  });

  test('commande non visible : absente du résultat, mais comptée dans le FIFO',
      () {
    final entries = [
      e(fee, -1000, order: 'OLD', minute: 1),
      e(fee, -1000, order: 'A', minute: 2),
      e(remit, 1000, minute: 3),
    ];
    final r = owed(entries, {'A'});
    expect(r.containsKey('OLD'), isFalse);
    expect(r, {'A': 1000}); // le crédit a éteint OLD, plus ancienne
  });

  test('oracle : somme des restes = max(0, −solde) sur 300 séquences', () {
    final rnd = Random(20260915);
    for (var run = 0; run < 300; run++) {
      final entries = <PartnerLedgerEntry>[];
      final ids = <String>{};
      final n = 1 + rnd.nextInt(12);
      for (var i = 0; i < n; i++) {
        final order = 'o$run-$i';
        final minute = rnd.nextInt(600);
        switch (rnd.nextInt(4)) {
          case 0: // livrée, payée à la boutique → frais dus
            ids.add(order);
            entries.add(e(fee, -(100.0 + rnd.nextInt(3000)),
                order: order, minute: minute));
          case 1: // encaissée par le partenaire, reversée en partie
            final collected = 1000.0 + rnd.nextInt(9000);
            ids.add(order);
            entries
              ..add(e(sale, collected, order: order, minute: minute))
              ..add(e(fee, -(100.0 + rnd.nextInt(900)),
                  order: order, minute: minute))
              ..add(e(remit, -(rnd.nextInt(collected.toInt())).toDouble(),
                  order: order, minute: minute + 1));
          case 2: // règlement global de la boutique
            entries.add(e(remit, 100.0 + rnd.nextInt(4000), minute: minute));
          default: // avance
            entries.add(e(advance, 100.0 + rnd.nextInt(2000), minute: minute));
        }
      }
      final balance = entries.fold<double>(0, (s, x) => s + x.amount);
      final total = PartnerLedgerService.computeOrderDebts(entries, ids)
          .values
          .fold<double>(0, (s, d) => s + d.amount);
      expect(total, closeTo(max(0, -balance), 1e-6),
          reason: 'séquence $run, solde $balance');
    }
  });
}
