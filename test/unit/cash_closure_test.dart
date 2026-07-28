// Tests de la clôture de caisse aveugle X/Z (Lot C).
//
// Ce qui est en jeu : c'est LA mécanique antifraude du module. Elle ne vaut que
// par deux choses — un total attendu juste, et un écart calculé une seule
// façon. Un total attendu faux transforme un caissier honnête en suspect, ou
// masque un manquant réel.
//
// Le piège principal est le DOUBLE COMPTAGE : deux chemins d'encaissement
// coexistent (les règlements détaillés du service, et les commandes de l'écran
// Caisse qui n'en écrivent pas). Compter les deux pour une même commande gonfle
// la caisse attendue et fabrique un manquant de toutes pièces.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/services/cash_closure_service.dart';
import 'package:fortress/features/caisse/domain/entities/sale.dart';
import 'package:fortress/features/caisse/domain/entities/sale_item.dart';
import 'package:fortress/features/restaurant/domain/entities/cash_closure.dart';
import 'package:fortress/features/restaurant/domain/entities/payment.dart';

Payment _pay(String orderId, int amount,
        {String method = 'cash', int change = 0}) =>
    Payment(
      id: 'py_${orderId}_$method',
      shopId: 'shop_1',
      orderId: orderId,
      method: method,
      amount: amount,
      changeGiven: change,
      createdAt: DateTime(2026, 7, 28, 20),
    );

Sale _order(
  String id, {
  double total = 10000,
  PaymentMethod method = PaymentMethod.cash,
  double amountPaid = 0,
  PaymentStatus status = PaymentStatus.paid,
}) =>
    Sale(
      id: id,
      shopId: 'shop_1',
      items: [
        SaleItem(
          productId: 'p1',
          productName: 'Plat',
          unitPrice: total,
          priceBuy: 0,
          quantity: 1,
        ),
      ],
      paymentMethod: method,
      status: SaleStatus.completed,
      paymentStatus: status,
      amountPaid: amountPaid,
      createdAt: DateTime(2026, 7, 28, 19),
    );

void main() {
  group('CashClosure.varianceOf', () {
    test('déclaré − attendu, dans ce sens', () {
      // Le signe porte le sens : négatif = il manque de l'argent. L'inverser
      // ferait lire « excédent » sur un tiroir vidé.
      expect(CashClosure.varianceOf(48000, 50000), -2000);
      expect(CashClosure.varianceOf(52000, 50000), 2000);
      expect(CashClosure.varianceOf(50000, 50000), 0);
    });
  });

  group('Lecture d\'un écart', () {
    CashClosure closure(int declared, int system) => CashClosure(
          id: 'cc_1',
          shopId: 'shop_1',
          declaredCash: declared,
          systemCash: system,
          variance: CashClosure.varianceOf(declared, system),
          closedAt: DateTime(2026, 7, 28, 22),
        );

    test('un manquant est signalé comme tel', () {
      final c = closure(48000, 50000);
      expect(c.isShort, isTrue);
      expect(c.isBalanced, isFalse);
      expect(c.gap, 2000); // valeur absolue : le signe est porté par isShort
      expect(c.varianceLabel, 'Manquant');
    });

    test('un excédent n\'est pas un manquant', () {
      final c = closure(52000, 50000);
      expect(c.isShort, isFalse);
      expect(c.gap, 2000);
      expect(c.varianceLabel, 'Excédent');
    });

    test('une caisse juste n\'affiche aucun écart', () {
      final c = closure(50000, 50000);
      expect(c.isBalanced, isTrue);
      expect(c.gap, 0);
      expect(c.varianceLabel, 'Caisse juste');
    });
  });

  group('computeSystemCash', () {
    test('le fond de caisse fait partie de l\'attendu', () {
      // Sans lui, une caisse démarrant avec 20 000 F de monnaie afficherait
      // 20 000 F d'excédent tous les soirs.
      expect(
        CashClosureService.computeSystemCash(
            openingFloat: 20000, payments: const [], orders: const []),
        20000,
      );
    });

    test('seules les espèces entrent dans le tiroir', () {
      // MTN et carte n'y mettent rien : les compter ferait un manquant du
      // montant des transferts, chaque jour.
      final total = CashClosureService.computeSystemCash(
        openingFloat: 0,
        payments: [
          _pay('o1', 5000),
          _pay('o1', 7000, method: 'mtn_money'),
          _pay('o2', 3000, method: 'card'),
        ],
        orders: const [],
      );
      expect(total, 5000);
    });

    test('le rendu monnaie n\'est pas déduit deux fois', () {
      // `amount` est déjà net du rendu : le client a donné 10 000 pour 7 500,
      // il repart avec 2 500. Le tiroir gagne 7 500.
      final total = CashClosureService.computeSystemCash(
        openingFloat: 0,
        payments: [_pay('o1', 7500, change: 2500)],
        orders: const [],
      );
      expect(total, 7500);
    });

    test('une commande de l\'écran Caisse est comptée sur son total', () {
      // Pas de ligne de règlement pour ce chemin : c'est la commande elle-même
      // qui porte l'encaissement.
      final total = CashClosureService.computeSystemCash(
        openingFloat: 0,
        payments: const [],
        orders: [_order('o9', total: 12000)],
      );
      expect(total, 12000);
    });

    test('une commande avec règlements n\'est PAS recomptée', () {
      // LE piège : addition de 12 000 réglée 5 000 espèces + 7 000 MTN. Sans
      // exclusion, la caisse attendrait 5 000 + 12 000 = 17 000 et
      // annoncerait 12 000 F de manquant à un caissier irréprochable.
      final total = CashClosureService.computeSystemCash(
        openingFloat: 0,
        payments: [_pay('o1', 5000), _pay('o1', 7000, method: 'mtn_money')],
        orders: [_order('o1', total: 12000)],
      );
      expect(total, 5000);
    });

    test('une commande réglée entièrement par MTN n\'apporte rien', () {
      final total = CashClosureService.computeSystemCash(
        openingFloat: 0,
        payments: const [],
        orders: [_order('o1', method: PaymentMethod.mobileMoney)],
      );
      expect(total, 0);
    });

    test('une commande partiellement payée ne compte que l\'encaissé', () {
      // Vente à crédit : 4 000 versés sur 10 000. Le tiroir n'a reçu que
      // 4 000 — compter le total ferait apparaître un manquant de 6 000.
      final total = CashClosureService.computeSystemCash(
        openingFloat: 0,
        payments: const [],
        orders: [
          _order('o1',
              total: 10000,
              amountPaid: 4000,
              status: PaymentStatus.partial),
        ],
      );
      expect(total, 4000);
    });

    test('une commande soldée sans amountPaid compte pour son total', () {
      // Commandes antérieures au suivi de paiement : `amountPaid` est resté à
      // zéro alors que l'argent est bien entré.
      final total = CashClosureService.computeSystemCash(
        openingFloat: 0,
        payments: const [],
        orders: [_order('o1', total: 8000, amountPaid: 0)],
      );
      expect(total, 8000);
    });

    test('les sorties d\'espèces sont déduites du tiroir', () {
      // Lot E : l'argent du marché part souvent directement de la caisse. Sans
      // cette déduction, un achat de 30 000 F apparaît le soir comme un
      // manquant de 30 000 F, et le caissier est suspecté d'un vol qu'il n'a
      // pas commis.
      final total = CashClosureService.computeSystemCash(
        openingFloat: 20000,
        payments: [_pay('o1', 50000)],
        orders: const [],
        cashOut: 30000,
      );
      expect(total, 40000);
    });

    test('une sortie supérieure aux encaissements donne un attendu négatif', () {
      // Cas réel d'un matin : on achète avant d'avoir vendu. Le chiffre doit
      // rester juste plutôt que d'être plafonné à zéro, sinon l'écart du soir
      // serait faux du montant écrêté.
      final total = CashClosureService.computeSystemCash(
        openingFloat: 10000,
        payments: const [],
        orders: const [],
        cashOut: 25000,
      );
      expect(total, -15000);
    });

    test('cas complet : fond + service + comptoir', () {
      final total = CashClosureService.computeSystemCash(
        openingFloat: 20000,
        payments: [
          _pay('o1', 12000), // addition réglée en espèces
          _pay('o2', 9000, method: 'orange_money'), // pas dans le tiroir
        ],
        orders: [
          _order('o1', total: 12000), // déjà couverte par ses règlements
          _order('o2', total: 9000), // idem
          _order('o3', total: 5000), // écran Caisse, espèces
          _order('o4', total: 4000, method: PaymentMethod.card),
        ],
      );
      expect(total, 20000 + 12000 + 5000);
    });
  });

  group('Sérialisation', () {
    final c = CashClosure(
      id: 'cc_1',
      shopId: 'shop_1',
      cashierId: 'u1',
      cashierName: 'Awa',
      closureType: 'Z',
      declaredCash: 48000,
      systemCash: 50000,
      variance: -2000,
      openingFloat: 20000,
      periodStart: DateTime(2026, 7, 28, 8),
      note: 'Billet rendu en trop à midi',
      closedAt: DateTime(2026, 7, 28, 22),
    );

    test('aller-retour sans perte', () {
      final back = CashClosure.fromMap(c.toMap());
      expect(back.closureType, 'Z');
      expect(back.declaredCash, 48000);
      expect(back.systemCash, 50000);
      expect(back.variance, -2000);
      expect(back.openingFloat, 20000);
      expect(back.cashierName, 'Awa');
      expect(back.note, 'Billet rendu en trop à midi');
      expect(back.periodStart, isNotNull);
    });

    test('l\'écart STOCKÉ est conservé, pas recalculé', () {
      // C'est un constat daté : si la définition du total système évolue, le
      // chiffre constaté ce soir-là doit rester lisible tel quel.
      final raw = c.toMap()..['variance'] = -7777;
      expect(CashClosure.fromMap(raw).variance, -7777);
    });

    test('un écart absent est reconstruit', () {
      final raw = c.toMap()..remove('variance');
      expect(CashClosure.fromMap(raw).variance, -2000);
    });

    test('un type inconnu retombe sur le contrôle X', () {
      // Un « Z » inventé clôturerait une période et déplacerait le point de
      // départ de tous les comptages suivants. Le repli le plus sûr est le
      // contrôle, qui ne clôt rien.
      final raw = c.toMap()..['closure_type'] = 'W';
      expect(CashClosure.fromMap(raw).closureType, 'X');
      expect(CashClosure.fromMap(raw).isZ, isFalse);
    });

    test('le type est normalisé en majuscule', () {
      final raw = c.toMap()..['closure_type'] = 'z';
      expect(CashClosure.fromMap(raw).isZ, isTrue);
    });
  });
}
