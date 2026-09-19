// Tests unitaires purs du moteur de décision stock à la transition de statut.
// Couvre TOUTE la matrice de transitions autorisées (cf. SaleStatusTransitions)
// × état du flag `stock_reserved` (true/false), sans Hive ni Supabase.
//
// Invariant métier — « stock engagé » :
//   * processing | completed → le stock DOIT être sorti des disponibles ;
//   * tout autre statut       → le stock NE doit PAS être sorti.
// Le moteur réconcilie l'état réel (flag `reserved` OU ancien statut completed)
// vers l'état désiré, de manière idempotente et rétro-compatible.
import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/caisse/domain/entities/sale.dart';
import 'package:fortress/features/caisse/domain/stock_engagement.dart';

/// Helper d'assertion : (old, new, reserved) → (action, nouveau flag).
void _expect(
  SaleStatus from,
  SaleStatus to, {
  required bool reserved,
  required StockAction action,
  required bool newReserved,
}) {
  final d = StockEngagement.decide(
    oldStatus: from, newStatus: to, reserved: reserved);
  expect(d.action, action,
      reason: '${from.name}→${to.name} (reserved=$reserved) : action');
  expect(d.reserved, newReserved,
      reason: '${from.name}→${to.name} (reserved=$reserved) : flag');
}

void main() {
  group('StockEngagement.engagesStock', () {
    test('processing et completed engagent le stock', () {
      expect(StockEngagement.engagesStock(SaleStatus.processing), isTrue);
      expect(StockEngagement.engagesStock(SaleStatus.completed), isTrue);
    });
    test('scheduled / cancelled / refused / refunded n\'engagent pas', () {
      expect(StockEngagement.engagesStock(SaleStatus.scheduled), isFalse);
      expect(StockEngagement.engagesStock(SaleStatus.cancelled), isFalse);
      expect(StockEngagement.engagesStock(SaleStatus.refused), isFalse);
      expect(StockEngagement.engagesStock(SaleStatus.refunded), isFalse);
    });
  });

  group('Depuis SCHEDULED', () {
    test('scheduled→processing : envoi livreur → décrément (réserve)', () {
      _expect(SaleStatus.scheduled, SaleStatus.processing,
          reserved: false, action: StockAction.decrement, newReserved: true);
    });
    test('scheduled→processing déjà réservé : idempotent (aucun mouvement)', () {
      _expect(SaleStatus.scheduled, SaleStatus.processing,
          reserved: true, action: StockAction.none, newReserved: true);
    });
    test('scheduled→completed direct (sans tournée) : décrément', () {
      _expect(SaleStatus.scheduled, SaleStatus.completed,
          reserved: false, action: StockAction.decrement, newReserved: true);
    });
    test('scheduled→cancelled : aucun stock engagé → aucun mouvement', () {
      _expect(SaleStatus.scheduled, SaleStatus.cancelled,
          reserved: false, action: StockAction.none, newReserved: false);
    });
    test('scheduled→refused : aucun stock engagé → aucun mouvement', () {
      _expect(SaleStatus.scheduled, SaleStatus.refused,
          reserved: false, action: StockAction.none, newReserved: false);
    });
  });

  group('Depuis PROCESSING (nouveau flux — stock réservé)', () {
    test('processing→completed : déjà sorti → aucun double décrément', () {
      _expect(SaleStatus.processing, SaleStatus.completed,
          reserved: true, action: StockAction.none, newReserved: true);
    });
    test('processing→scheduled (reprogrammation) : restitution', () {
      _expect(SaleStatus.processing, SaleStatus.scheduled,
          reserved: true, action: StockAction.restore, newReserved: false);
    });
    test('processing→cancelled : restitution', () {
      _expect(SaleStatus.processing, SaleStatus.cancelled,
          reserved: true, action: StockAction.restore, newReserved: false);
    });
    test('processing→refused : restitution', () {
      _expect(SaleStatus.processing, SaleStatus.refused,
          reserved: true, action: StockAction.restore, newReserved: false);
    });
  });

  group('Depuis PROCESSING (legacy — flag absent, stock jamais sorti)', () {
    test('processing→completed legacy : décrément (sortie tardive)', () {
      _expect(SaleStatus.processing, SaleStatus.completed,
          reserved: false, action: StockAction.decrement, newReserved: true);
    });
    test('processing→scheduled legacy : rien à restituer', () {
      _expect(SaleStatus.processing, SaleStatus.scheduled,
          reserved: false, action: StockAction.none, newReserved: false);
    });
    test('processing→cancelled legacy : rien à restituer', () {
      _expect(SaleStatus.processing, SaleStatus.cancelled,
          reserved: false, action: StockAction.none, newReserved: false);
    });
  });

  group('Depuis COMPLETED', () {
    test('completed→refunded (flux réservé) : restitution', () {
      _expect(SaleStatus.completed, SaleStatus.refunded,
          reserved: true, action: StockAction.restore, newReserved: false);
    });
    test('completed→refunded (POS direct / legacy, flag absent) : restitution',
        () {
      // Une vente POS naît `completed` avec stock décrémenté à la création mais
      // SANS flag : l'ancien statut completed suffit à savoir que le stock est
      // sorti → le remboursement le restitue quand même.
      _expect(SaleStatus.completed, SaleStatus.refunded,
          reserved: false, action: StockAction.restore, newReserved: false);
    });
  });

  group('Cycle de vie complet (enchaînement réaliste)', () {
    test('scheduled→processing→completed→refunded : un seul décrément, '
        'une seule restitution', () {
      // 1. Envoi livreur → décrément, flag posé.
      var d = StockEngagement.decide(
          oldStatus: SaleStatus.scheduled,
          newStatus: SaleStatus.processing,
          reserved: false);
      expect(d.action, StockAction.decrement);
      var reserved = d.reserved; // true

      // 2. Encaissement → rien (déjà sorti).
      d = StockEngagement.decide(
          oldStatus: SaleStatus.processing,
          newStatus: SaleStatus.completed,
          reserved: reserved);
      expect(d.action, StockAction.none);
      reserved = d.reserved; // true

      // 3. Remboursement → restitution unique.
      d = StockEngagement.decide(
          oldStatus: SaleStatus.completed,
          newStatus: SaleStatus.refunded,
          reserved: reserved);
      expect(d.action, StockAction.restore);
      reserved = d.reserved; // false
      expect(reserved, isFalse);
    });

    test('scheduled→processing→scheduled→processing : re-réservation propre',
        () {
      // Envoi.
      var d = StockEngagement.decide(
          oldStatus: SaleStatus.scheduled,
          newStatus: SaleStatus.processing,
          reserved: false);
      expect(d.action, StockAction.decrement);
      var reserved = d.reserved; // true

      // Reprogrammation → restitution.
      d = StockEngagement.decide(
          oldStatus: SaleStatus.processing,
          newStatus: SaleStatus.scheduled,
          reserved: reserved);
      expect(d.action, StockAction.restore);
      reserved = d.reserved; // false

      // Re-envoi → re-décrément.
      d = StockEngagement.decide(
          oldStatus: SaleStatus.scheduled,
          newStatus: SaleStatus.processing,
          reserved: reserved);
      expect(d.action, StockAction.decrement);
      expect(d.reserved, isTrue);
    });
  });

  group('INVARIANT global : l\'état du flag suit toujours l\'engagement', () {
    test('après décision, reserved == engagesStock(newStatus) pour tout cas '
        'non-legacy cohérent', () {
      const all = SaleStatus.values;
      for (final from in all) {
        for (final to in all) {
          if (!SaleStatusTransitions.canTransition(from, to)) continue;
          for (final reserved in [true, false]) {
            final d = StockEngagement.decide(
                oldStatus: from, newStatus: to, reserved: reserved);
            // Le flag résultant doit refléter si le stock est censé être sorti
            // au NOUVEAU statut — sauf les cas legacy processing (stock jamais
            // sorti, flag faux) que decide() laisse converger à la prochaine
            // transition.
            final wasOut = reserved || from == SaleStatus.completed;
            final wantOut = StockEngagement.engagesStock(to);
            if (wantOut && wasOut) {
              expect(d.reserved, isTrue,
                  reason: '$from→$to reserved=$reserved : flag doit rester vrai');
            }
            if (!wantOut) {
              expect(d.reserved, isFalse,
                  reason: '$from→$to reserved=$reserved : flag doit tomber');
            }
          }
        }
      }
    });
  });
}
