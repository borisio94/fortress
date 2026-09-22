// Le motif d'une remise était exigé, puis perdu.
//
// `bill_page.dart:607` refuse de valider une remise sans motif. Ce motif
// partait ensuite dans `ManagerGate.require(details: …)`, donc dans
// `activity_logs`, et `applyDiscount(order, amount)` n'écrivait QUE le
// montant. Ni l'addition, ni la facture, ni les rapports ne le voyaient.
//
// Un champ imposé au serveur qui n'atterrit nulle part est le pire des deux
// mondes : il coûte du temps et ne rend rien.
//
// POURQUOI PAS RELIRE LE JOURNAL : il n'est pas lisible hors ligne, et un
// restaurant travaille hors ligne. `ActivityLogService.log` passe par
// `bgInsert`, qui écrit dans la file d'attente et pas dans Hive ; la boîte
// locale n'est remplie qu'en tirant depuis le serveur. Une remise accordée
// pendant une coupure aurait son motif nulle part jusqu'au retour du réseau.
// Il doit voyager avec la commande — `orders.discount_reason`, hotfix_181.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/restaurant/domain/discount_reason.dart';

void main() {
  group('Le motif écrit sur la commande', () {
    test('UNE REMISE ACCORDÉE GARDE SON MOTIF', () {
      // LE test de ce lot. C'est exactement ce qui se perdait.
      expect(
          discountReasonFor(amount: 2000, reason: 'Geste commercial'),
          'Geste commercial');
    });

    test('les espaces de bord sont retirés', () {
      // Le champ est saisi debout, entre deux tables : un espace de trop ne
      // doit pas se retrouver sur une facture.
      expect(discountReasonFor(amount: 2000, reason: '  Erreur cuisine  '),
          'Erreur cuisine');
    });

    test('RETIRER LA REMISE EMPORTE SON MOTIF', () {
      // Sans ça, « geste commercial » resterait collé à une addition qui ne
      // porte plus aucune remise — et se lirait sur la facture, où il ne
      // voudrait plus rien dire. `bill_page` traite déjà le montant nul comme
      // un retrait ; le motif doit suivre le même sort.
      expect(discountReasonFor(amount: 0, reason: 'Geste commercial'), isNull);
    });

    test('un montant négatif est un retrait, lui aussi', () {
      // Défensif : le formulaire refuse déjà le négatif, mais les appels
      // programmatiques ne passent pas par lui.
      expect(discountReasonFor(amount: -500, reason: 'Geste'), isNull);
    });

    test('un motif vide ou blanc vaut absence', () {
      // Le formulaire l'interdit, mais les commandes antérieures au
      // hotfix_181 et les appels programmatiques ne passent pas par lui.
      // Écrire une chaîne vide en base ferait apparaître une ligne « Motif »
      // vide sur l'addition.
      expect(discountReasonFor(amount: 2000, reason: ''), isNull);
      expect(discountReasonFor(amount: 2000, reason: '   '), isNull);
    });

    test('le montant décide AVANT le motif', () {
      // Les deux conditions se croisent ; l'ordre compte. Un retrait de
      // remise avec un motif non vide reste un retrait.
      expect(discountReasonFor(amount: 0, reason: ''), isNull);
      expect(discountReasonFor(amount: 0, reason: 'peu importe'), isNull);
    });
  });
}
