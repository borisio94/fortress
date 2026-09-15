// Tests des consignes d'emballages (Lot B).
//
// Ce qui est en jeu : une consigne, c'est de l'argent encaissé qui appartient
// encore au client. Une erreur de comptage rend une caution jamais versée, ou
// laisse une bouteille réclamée à quelqu'un qui l'a déjà rapportée.
//
// `BottleDepositService` lit Hive et n'est pas testable en unitaire ; les
// règles (retour plafonné, statut, montant restant) vivent sur l'entité.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/restaurant/domain/entities/bottle_deposit.dart';

/// Statuts acceptés par le CHECK SQL de `bottle_deposits.status` (hotfix_146).
const _kSqlStatuses = {
  'pending',
  'partially_returned',
  'fully_returned',
  'lost',
};

/// Catégories acceptées par le CHECK SQL de `losses` après hotfix_146.
const _kSqlLossCategories = {
  'casse',
  'reste_invendu',
  'plat_mal_fait',
  'non_paye',
  'materiel_endommage',
  'ecart_inventaire',
  'consigne_perdue',
  'autre',
};

BottleDeposit _deposit({
  int quantity = 12,
  int perUnit = 500,
  int returned = 0,
  String? status,
}) =>
    BottleDeposit(
      id: 'bd_1',
      shopId: 'shop_1',
      orderId: 'order_1',
      label: 'Bouteille 65 cl',
      quantity: quantity,
      depositPerUnit: perUnit,
      returnedQuantity: returned,
      status: status ?? BottleDeposit.statusFor(quantity, returned),
      holder: 'Table 5',
      createdAt: DateTime(2026, 7, 28),
    );

void main() {
  group('Statut ↔ SQL', () {
    test('les statuts dérivés existent tous côté SQL', () {
      for (final r in [0, 5, 12, 30]) {
        expect(_kSqlStatuses, contains(BottleDeposit.statusFor(12, r)));
      }
      expect(_kSqlStatuses, contains('lost'));
    });

    test('la catégorie de perte émise existe côté SQL', () {
      // `consigne_perdue` est écrite par BottleDepositService.declareLost : hors
      // CHECK, Postgres rejetterait l'upsert et l'op serait droppée en silence.
      expect(_kSqlLossCategories, contains('consigne_perdue'));
    });

    test('statusFor suit les quantités', () {
      expect(BottleDeposit.statusFor(12, 0), 'pending');
      expect(BottleDeposit.statusFor(12, 5), 'partially_returned');
      expect(BottleDeposit.statusFor(12, 12), 'fully_returned');
      // Sur-retour : traité comme un retour complet, jamais comme un statut
      // intermédiaire.
      expect(BottleDeposit.statusFor(12, 20), 'fully_returned');
    });
  });

  group('Montants', () {
    test('le total consigné est quantité × caution', () {
      expect(_deposit().totalAmount, 6000);
    });

    test('seuls les emballages dehors restent dus', () {
      // 5 rendus sur 12 → 7 × 500 encore à rembourser.
      final d = _deposit(returned: 5);
      expect(d.outstanding, 7);
      expect(d.outstandingAmount, 3500);
    });

    test('rien n\'est dû quand tout est revenu', () {
      final d = _deposit(returned: 12);
      expect(d.outstanding, 0);
      expect(d.outstandingAmount, 0);
      expect(d.isClosed, isTrue);
    });

    test('un retour incohérent ne crée pas de dû négatif', () {
      // Donnée corrompue ou saisie manuelle en base : on ne doit jamais
      // afficher « −3 bouteilles » ni un montant négatif.
      final d = _deposit(returned: 20);
      expect(d.outstanding, 0);
      expect(d.outstandingAmount, 0);
    });
  });

  group('withReturn', () {
    test('un retour partiel décompte exactement', () {
      final d = _deposit().withReturn(5);
      expect(d.returnedQuantity, 5);
      expect(d.status, 'partially_returned');
      expect(d.outstanding, 7);
    });

    test('les retours s\'accumulent jusqu\'au solde', () {
      final d = _deposit().withReturn(5).withReturn(7);
      expect(d.returnedQuantity, 12);
      expect(d.status, 'fully_returned');
      expect(d.isClosed, isTrue);
    });

    test('un retour excédentaire est plafonné', () {
      // Le client rapporte 20 bouteilles pour 12 consignées : on ne rembourse
      // que ce qui a été versé.
      final d = _deposit().withReturn(20);
      expect(d.returnedQuantity, 12);
      expect(d.outstandingAmount, 0);
    });

    test('un retour nul ou négatif ne change rien', () {
      final base = _deposit(returned: 3);
      expect(base.withReturn(0).returnedQuantity, 3);
      expect(base.withReturn(-4).returnedQuantity, 3);
    });

    test('une consigne soldée n\'accepte plus de retour', () {
      final d = _deposit(returned: 12).withReturn(5);
      expect(d.returnedQuantity, 12);
    });
  });

  group('Consigne perdue', () {
    test('perdue reste perdue, même partiellement rendue', () {
      final d = _deposit(returned: 4, status: 'lost');
      expect(d.isLost, isTrue);
      expect(d.isClosed, isTrue);
      // Le montant de la perte est ce qui restait dehors, pas la consigne
      // entière : ce qui est revenu a bien été rendu au client.
      expect(d.outstandingAmount, 4000);
    });

    test('le statut « lost » survit à un aller-retour toMap/fromMap', () {
      // Il ne se déduit PAS des quantités : s'il n'était pas conservé tel quel,
      // une consigne perdue redeviendrait « due » à la première relecture et
      // réapparaîtrait dans la liste des retours à réclamer.
      final d = _deposit(returned: 4, status: 'lost');
      expect(BottleDeposit.fromMap(d.toMap()).status, 'lost');
    });
  });

  group('Sérialisation', () {
    test('aller-retour sans perte', () {
      final back = BottleDeposit.fromMap(_deposit(returned: 3).toMap());
      expect(back.id, 'bd_1');
      expect(back.orderId, 'order_1');
      expect(back.label, 'Bouteille 65 cl');
      expect(back.quantity, 12);
      expect(back.depositPerUnit, 500);
      expect(back.returnedQuantity, 3);
      expect(back.holder, 'Table 5');
      expect(back.status, 'partially_returned');
    });

    test('un statut inconnu retombe sur le statut dérivé', () {
      final raw = _deposit(returned: 3).toMap()..['status'] = 'zombie';
      expect(BottleDeposit.fromMap(raw).status, 'partially_returned');
    });

    test('un libellé vide reçoit un repli lisible', () {
      // La liste des retours doit rester lisible : une ligne sans nom ne se
      // réclame pas.
      final raw = _deposit().toMap()..['label'] = '  ';
      expect(BottleDeposit.fromMap(raw).label, 'Consigne');
    });

    test('les références vides sont lues comme absentes', () {
      final raw = _deposit().toMap()
        ..['order_id'] = ''
        ..['product_id'] = null
        ..['holder'] = '   ';
      final back = BottleDeposit.fromMap(raw);
      expect(back.orderId, isNull);
      expect(back.productId, isNull);
      expect(back.holder, isNull);
    });
  });
}
