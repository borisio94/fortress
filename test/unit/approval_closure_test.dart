import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/caisse/domain/approval_closure.dart';

void main() {
  group('ApprovalClosure.reconcile — vente « à choisir sur place »', () {
    test('tout gardé → rien retourné', () {
      final r = ApprovalClosure.reconcile(
        reserved: {'a': 2, 'b': 1},
        kept: {'a': 2, 'b': 1},
      );
      expect(r.kept, {'a': 2, 'b': 1});
      expect(r.returned, {'a': 0, 'b': 0});
      expect(r.totalKept, 3);
      expect(r.totalReturned, 0);
    });

    test('rien gardé → tout retourné', () {
      final r = ApprovalClosure.reconcile(
        reserved: {'a': 2, 'b': 3},
        kept: {}, // l\'opérateur n\'a coché aucun gardé
      );
      expect(r.kept, {'a': 0, 'b': 0});
      expect(r.returned, {'a': 2, 'b': 3});
      expect(r.totalReturned, 5);
    });

    test('partiel : gardé < réservé → retourné = réservé − gardé', () {
      final r = ApprovalClosure.reconcile(
        reserved: {'a': 5},
        kept: {'a': 2},
      );
      expect(r.kept['a'], 2);
      expect(r.returned['a'], 3);
    });

    test('gardé > réservé → borné au réservé (jamais de stock négatif)', () {
      final r = ApprovalClosure.reconcile(
        reserved: {'a': 2},
        kept: {'a': 99}, // saisie erronée
      );
      expect(r.kept['a'], 2); // borné
      expect(r.returned['a'], 0);
    });

    test('gardé négatif → ramené à 0 → tout retourné', () {
      final r = ApprovalClosure.reconcile(
        reserved: {'a': 3},
        kept: {'a': -5},
      );
      expect(r.kept['a'], 0);
      expect(r.returned['a'], 3);
    });

    test('article réservé à 0 ou négatif → ignoré', () {
      final r = ApprovalClosure.reconcile(
        reserved: {'a': 0, 'b': -1, 'c': 2},
        kept: {'a': 1, 'b': 1, 'c': 1},
      );
      expect(r.kept.containsKey('a'), false);
      expect(r.kept.containsKey('b'), false);
      expect(r.kept['c'], 1);
      expect(r.returned['c'], 1);
    });

    test('clé gardée inconnue (pas dans réservé) → ignorée', () {
      final r = ApprovalClosure.reconcile(
        reserved: {'a': 2},
        kept: {'a': 1, 'zzz': 10}, // 'zzz' n\'a jamais été réservé
      );
      expect(r.kept.keys.toSet(), {'a'});
      expect(r.returned.keys.toSet(), {'a'});
    });

    test('INVARIANT : gardé + retourné == réservé, pour chaque article', () {
      final reserved = {'a': 4, 'b': 7, 'c': 1, 'd': 0, 'e': 10};
      final kept = {'a': 4, 'b': 3, 'c': 0, 'e': 25};
      final r = ApprovalClosure.reconcile(reserved: reserved, kept: kept);
      for (final entry in reserved.entries) {
        if (entry.value <= 0) continue; // ignorés
        final id = entry.key;
        expect(
          (r.kept[id] ?? 0) + (r.returned[id] ?? 0),
          entry.value,
          reason: 'gardé+retourné doit égaler le réservé pour $id',
        );
      }
      // Conservation globale : tout le réservé (positif) est réparti.
      final totalReserved =
          reserved.values.where((v) => v > 0).fold(0, (s, v) => s + v);
      expect(r.totalKept + r.totalReturned, totalReserved);
    });

    test('helpers nonZero filtrent les quantités nulles', () {
      final r = ApprovalClosure.reconcile(
        reserved: {'a': 2, 'b': 2},
        kept: {'a': 2, 'b': 0},
      );
      expect(r.keptNonZero, {'a': 2});
      expect(r.returnedNonZero, {'b': 2});
    });
  });
}
