// Payer en deux fois, sans jamais payer à moitié.
//
// La feuille d'encaissement savait empiler plusieurs règlements. Cette
// mécanique a été retirée le 2026-08-03, et sa doc dit pourquoi : elle servait
// aussi l'acompte, elle imposait une saisie chiffrée à chaque encaissement, et
// « le bouton pouvait valider une addition partiellement payée, laissant une
// créance sans que personne ne l'ait voulu ».
//
// Le règlement MIXTE revient — 4 000 en espèces et le reste en MTN est le cas
// courant ici. L'acompte, non. La règle qui les sépare tient en une ligne : on
// ne valide que si le total est couvert.
//
// Conséquence directe, et c'est le second constat du lot : le message
// « encaissée — rendre X » de `bill_page.dart:247` cesse d'être du code mort.
// `change` ne pouvait pas dépasser zéro tant que `received` valait toujours
// `due` ; avec une ligne d'espèces excédentaire, il le peut.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/services/payment_service.dart';
import 'package:fortress/features/restaurant/domain/entities/payment.dart';
import 'package:fortress/features/restaurant/domain/mixed_payment.dart';

PaymentEntry _cash(int n) => PaymentEntry(mode: PaymentMode.cash, received: n);
PaymentEntry _mtn(int n) =>
    PaymentEntry(mode: PaymentMode.mtnMoney, received: n);

void main() {
  group('Le cas courant ne coûte rien', () {
    test('un mode, le montant exact : ça valide', () {
      final s = mixedPaymentState(
          due: 5000, entries: singleEntry(due: 5000, mode: PaymentMode.cash));
      expect(s.canValidate, isTrue);
      expect(s.blocker, isNull);
      expect(s.remaining, 0);
      // Rien à rendre : c'est le chemin d'avant, inchangé.
      expect(s.change, 0);
    });

    test('la référence de transaction suit le règlement', () {
      final e = singleEntry(
          due: 5000, mode: PaymentMode.mtnMoney, reference: 'MP240923.1234');
      expect(e.single.reference, 'MP240923.1234');
    });
  });

  group('LE RÈGLEMENT MIXTE', () {
    test('espèces + MTN qui couvrent l\'addition : ça valide', () {
      // LE cas que ce lot rouvre.
      final s = mixedPaymentState(due: 5000, entries: [_cash(3000), _mtn(2000)]);
      expect(s.canValidate, isTrue);
      expect(s.remaining, 0);
      expect(s.split.isMixed, isTrue);
    });

    test('trois règlements se cumulent aussi', () {
      final s = mixedPaymentState(
          due: 9000, entries: [_cash(4000), _mtn(3000), _cash(2000)]);
      expect(s.canValidate, isTrue);
      expect(s.remaining, 0);
    });
  });

  group('L\'ACOMPTE RESTE FERMÉ', () {
    test('une addition à moitié payée NE VALIDE PAS', () {
      // Le défaut exact que le retrait du 2026-08-03 visait : le bouton
      // pouvait clore une addition partiellement réglée, et la créance
      // naissait sans que personne ne l'ait décidé.
      final s = mixedPaymentState(due: 5000, entries: [_cash(2000)]);
      expect(s.canValidate, isFalse);
      expect(s.remaining, 3000);
    });

    test('le blocage DIT COMBIEN IL MANQUE', () {
      // Le caissier doit réclamer un chiffre, pas le soustraire de tête.
      final s = mixedPaymentState(due: 5000, entries: [_cash(2000)]);
      expect(s.blocker, contains('3000'));
    });

    test('aucun règlement saisi : rien à valider', () {
      final s = mixedPaymentState(due: 5000, entries: const []);
      expect(s.canValidate, isFalse);
      expect(s.blocker, isNotNull);
    });

    test('il manque UN FRANC : ça ne valide toujours pas', () {
      final s = mixedPaymentState(due: 5000, entries: [_cash(4999)]);
      expect(s.canValidate, isFalse);
      expect(s.remaining, 1);
    });
  });

  group('LE RENDU DE MONNAIE, qui n\'existait pas', () {
    test('un excédent en ESPÈCES devient un rendu, et ça valide', () {
      // `change` valait toujours 0 tant que `received == due`. Le message
      // « encaissée — rendre X » de l'addition était donc inatteignable.
      final s = mixedPaymentState(due: 5000, entries: [_cash(10000)]);
      expect(s.canValidate, isTrue);
      expect(s.change, 5000);
      expect(s.split.applied, 5000);
    });

    test('un excédent en MTN NE SE REND PAS, et bloque', () {
      // On ne rend pas la monnaie d'un transfert : la somme est partie, et
      // l'encaisser laisserait 1 000 de trop dans les comptes du jour.
      final s = mixedPaymentState(due: 5000, entries: [_mtn(6000)]);
      expect(s.canValidate, isFalse);
      expect(s.blocker, contains('transfert'));
    });

    test('mixte avec appoint en espèces : le rendu sort du cash', () {
      // 3 000 par MTN, puis 3 000 en espèces sur 5 000 dus : le transfert
      // s'impute en entier, les espèces couvrent le reste et rendent 1 000.
      final s = mixedPaymentState(due: 5000, entries: [_mtn(3000), _cash(3000)]);
      expect(s.canValidate, isTrue);
      expect(s.change, 1000);
      expect(s.remaining, 0);
    });

    test('l\'ordre compte : l\'espèces d\'abord absorbe, le MTN déborde', () {
      // Mêmes montants, ordre inverse : les espèces prennent tout le dû, et
      // le transfert qui suit n'a plus rien à imputer — donc il déborde.
      final s = mixedPaymentState(due: 5000, entries: [_cash(5000), _mtn(3000)]);
      expect(s.canValidate, isFalse);
      expect(s.blocker, contains('transfert'));
    });
  });
}
