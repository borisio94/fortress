// Tests de l'encaissement d'une addition (Lot A) — règlement mixte et rendu
// monnaie.
//
// Ce qui est en jeu : ce calcul décide de l'argent que le caissier rend au
// client, et du montant inscrit comme encaissé. Une erreur de répartition, et
// soit le client repart avec trop de monnaie, soit l'addition est réputée
// soldée alors qu'il reste dû.
//
// `PaymentService` lit Hive et n'est pas testable en unitaire ; `PaymentSplit`
// est pur, et c'est lui qui porte toute l'arithmétique.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/services/payment_service.dart';
import 'package:fortress/features/caisse/domain/entities/sale.dart'
    show PaymentMethod;
import 'package:fortress/features/restaurant/domain/entities/payment.dart';

/// Modes acceptés par le CHECK SQL de `payments.method` (hotfix_145).
const _kSqlMethods = {
  'cash',
  'mtn_money',
  'orange_money',
  'card',
  'credit',
};

PaymentEntry _cash(int received) =>
    PaymentEntry(mode: PaymentMode.cash, received: received);

PaymentEntry _mtn(int received) =>
    PaymentEntry(mode: PaymentMode.mtnMoney, received: received);

void main() {
  group('PaymentMode ↔ SQL', () {
    test('toutes les clés émises existent côté SQL', () {
      // Une valeur hors CHECK est rejetée par Postgres et l'écriture disparaît
      // après dix essais, sans bruit.
      for (final m in PaymentMode.values) {
        expect(_kSqlMethods, contains(m.key),
            reason: '« ${m.key} » absente du CHECK SQL de payments.method');
      }
    });

    test('les opérateurs mobiles retombent sur le Mobile Money générique', () {
      // `orders.payment_method` ne connaît pas MTN/Orange : le détail vit dans
      // `payments`, la colonne historique doit rester lisible par l'existant.
      expect(PaymentMode.mtnMoney.generic, PaymentMethod.mobileMoney);
      expect(PaymentMode.orangeMoney.generic, PaymentMethod.mobileMoney);
      expect(PaymentMode.cash.generic, PaymentMethod.cash);
      expect(PaymentMode.card.generic, PaymentMethod.card);
    });

    test('seules les espèces rendent la monnaie', () {
      for (final m in PaymentMode.values) {
        expect(m.allowsChange, m == PaymentMode.cash,
            reason: '${m.label} ne devrait pas rendre la monnaie');
      }
    });

    test('le crédit n\'est pas proposé au caissier', () {
      // La créance est DÉRIVÉE (encaissé < total) : la saisir comme règlement
      // la compterait deux fois, une fois en encaissé, une fois en dette.
      expect(PaymentMode.selectable, isNot(contains(PaymentMode.credit)));
      expect(PaymentMode.selectable.length, PaymentMode.values.length - 1);
    });

    test('une clé inconnue retombe sur les espèces', () {
      expect(PaymentMode.fromKey('bitcoin'), PaymentMode.cash);
      expect(PaymentMode.fromKey(null), PaymentMode.cash);
      expect(PaymentMode.fromKey(' MTN_MONEY '), PaymentMode.mtnMoney);
    });
  });

  group('PaymentSplit — appoint et rendu monnaie', () {
    test('appoint exact : rien à rendre, addition soldée', () {
      final s = PaymentSplit.compute(12000, [_cash(12000)]);
      expect(s.applied, 12000);
      expect(s.change, 0);
      expect(s.remaining, 0);
      expect(s.isSettled, isTrue);
    });

    test('billet plus gros : le surplus est rendu, pas encaissé', () {
      // 10 000 pour une addition de 7 500 → 2 500 à rendre. `applied` reste
      // l'addition : encaisser 10 000 fausserait la caisse du jour.
      final s = PaymentSplit.compute(7500, [_cash(10000)]);
      expect(s.applied, 7500);
      expect(s.change, 2500);
      expect(s.remaining, 0);
      expect(s.isSettled, isTrue);
    });

    test('règlement partiel : le reste dû est exact', () {
      final s = PaymentSplit.compute(12000, [_cash(5000)]);
      expect(s.applied, 5000);
      expect(s.remaining, 7000);
      expect(s.change, 0);
      expect(s.isSettled, isFalse);
    });

    test('addition à zéro : tout est rendu', () {
      // Cas limite d'une addition entièrement remisée : le client tend un
      // billet, on lui rend tout.
      final s = PaymentSplit.compute(0, [_cash(5000)]);
      expect(s.applied, 0);
      expect(s.change, 5000);
      expect(s.isSettled, isTrue);
    });

    test('un montant négatif ne crée pas d\'encaissement', () {
      final s = PaymentSplit.compute(-500, [_cash(-100)]);
      expect(s.due, 0);
      expect(s.applied, 0);
      expect(s.change, 0);
    });
  });

  group('PaymentSplit — règlement mixte', () {
    test('espèces + MTN soldent l\'addition', () {
      final s = PaymentSplit.compute(12000, [_cash(5000), _mtn(7000)]);
      expect(s.applied, 12000);
      expect(s.remaining, 0);
      expect(s.change, 0);
      expect(s.isMixed, isTrue);
      expect(s.hasOverpay, isFalse);
    });

    test('un transfert mobile ne peut pas être trop-perçu', () {
      // On ne rend pas la monnaie d'un MTN : le surplus est signalé, pas
      // encaissé — sinon la caisse afficherait plus que l'addition.
      final s = PaymentSplit.compute(10000, [_mtn(12000)]);
      expect(s.applied, 10000);
      expect(s.change, 0);
      expect(s.hasOverpay, isTrue);
    });

    test('les espèces en dernier absorbent le solde et rendent la monnaie', () {
      final s = PaymentSplit.compute(12000, [_mtn(7000), _cash(10000)]);
      expect(s.applied, 12000);
      expect(s.change, 5000); // 10 000 tendus pour 5 000 restants
      expect(s.isSettled, isTrue);
    });

    test('deux règlements du même mode ne sont pas « mixtes »', () {
      final s = PaymentSplit.compute(12000, [_cash(5000), _cash(7000)]);
      expect(s.isMixed, isFalse);
      expect(s.applied, 12000);
    });

    test('un règlement saisi après solde n\'ajoute rien à l\'addition', () {
      // Erreur de saisie classique : le caissier ressaisit une ligne. Le
      // deuxième règlement en espèces repart en rendu, il ne gonfle pas la
      // recette du jour.
      final s = PaymentSplit.compute(5000, [_cash(5000), _cash(2000)]);
      expect(s.applied, 5000);
      expect(s.change, 2000);
    });
  });

  group('PaymentSplit.dominantMethod', () {
    test('le plus gros montant l\'emporte', () {
      // 7 000 en MTN contre 5 000 en espèces → la commande est « Mobile Money ».
      final s = PaymentSplit.compute(12000, [_cash(5000), _mtn(7000)]);
      expect(s.dominantMethod, PaymentMethod.mobileMoney);
    });

    test('les règlements d\'un même mode se cumulent avant comparaison', () {
      // 4 000 + 4 000 en espèces battent 5 000 en MTN, alors qu'aucune ligne
      // d'espèces prise seule ne le ferait.
      final s = PaymentSplit.compute(
          13000, [_cash(4000), _cash(4000), _mtn(5000)]);
      expect(s.dominantMethod, PaymentMethod.cash);
    });

    test('à égalité, le premier saisi gagne', () {
      // Arbitraire mais STABLE : une addition réglée moitié-moitié ne doit pas
      // changer de mode d'une relecture à l'autre.
      final s = PaymentSplit.compute(10000, [_mtn(5000), _cash(5000)]);
      expect(s.dominantMethod, PaymentMethod.mobileMoney);
    });

    test('sans règlement, le défaut est les espèces', () {
      expect(PaymentSplit.compute(1000, const []).dominantMethod,
          PaymentMethod.cash);
    });
  });

  group('Payment — sérialisation', () {
    final p = Payment(
      id: 'py_1',
      shopId: 'shop_1',
      orderId: 'order_1',
      method: 'orange_money',
      amount: 7000,
      reference: 'OM-42',
      changeGiven: 0,
      createdAt: DateTime(2026, 7, 28, 12, 30),
    );

    test('aller-retour toMap/fromMap sans perte', () {
      final back = Payment.fromMap(p.toMap());
      expect(back.id, 'py_1');
      expect(back.orderId, 'order_1');
      expect(back.method, 'orange_money');
      expect(back.amount, 7000);
      expect(back.reference, 'OM-42');
      expect(back.mode, PaymentMode.orangeMoney);
    });

    test('une méthode inconnue est normalisée avant écriture', () {
      // Sans normalisation, la valeur repartirait vers Supabase et violerait
      // le CHECK — upsert rejeté, opération droppée silencieusement.
      final raw = p.toMap()..['method'] = 'paypal';
      expect(Payment.fromMap(raw).method, 'cash');
    });

    test('reçu = imputé + rendu', () {
      final espece = p.copyWith(method: 'cash', amount: 7500, changeGiven: 2500);
      expect(espece.received, 10000);
    });

    test('une référence vide est lue comme absente', () {
      final raw = p.toMap()..['reference'] = '   ';
      expect(Payment.fromMap(raw).reference, isNull);
    });
  });
}
