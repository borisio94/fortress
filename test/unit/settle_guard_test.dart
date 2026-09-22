// Seul le parcours empêchait d'encaisser deux fois la même addition.
//
// `caisse_page.dart:1232` masque le bouton « Encaisser » quand la commande est
// déjà `completed`. C'était le seul garde-fou : le service acceptait de
// rejouer la clôture, et `SaleStatusTransitions.canTransition` accepte
// `from == to` (`sale.dart:176`).
//
// CE QUE L'AUDIT LAISSAIT CROIRE, ET QUI ÉTAIT INEXACT : que la couche
// données doublerait tout. Elle est idempotente à dessein — `updateOrderStatus`
// garde le livre partenaire par `oldStatus != completed` et la compensation de
// stock par un `if (oldStatus == status) return` explicite, plus le drapeau
// persistant `stock_reserved`. Réémettre `completed` n'y bouge ni le stock ni
// les écritures partenaire, et `canTransition` accepte `from == to` POUR ÇA.
//
// CE QUI SE PERDAIT VRAIMENT, et que ce lot referme :
//
//   * `PaymentService.recordSplit` forge un identifiant neuf à chaque appel.
//     Un second encaissement écrit une SECONDE ligne de règlement, et la
//     clôture de caisse les somme (`cash_closure_service.dart:189`). Le fond
//     attendu monte d'un montant que personne n'a reçu : le caissier passe
//     pour manquant, du montant de l'addition.
//   * `consumeStockFor` décrémente le décompte du jour une seconde fois.
//
// LE CAS N'EST PAS THÉORIQUE : le plan de salle est prévu pour deux appareils
// — « tablette salle / téléphone serveur ». Le premier encaisse ; le second,
// dont Hive n'a pas reçu la mise à jour, voit encore le bouton.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/caisse/domain/entities/sale.dart';
import 'package:fortress/features/restaurant/domain/settle_guard.dart';

void main() {
  group('Une addition déjà encaissée', () {
    test('NE SE RÉ-ENCAISSE PAS', () {
      // LE test de ce lot. Sans lui, le second appareil écrit une ligne de
      // règlement de plus et le fond attendu ment d'autant.
      expect(isAlreadySettled(SaleStatus.completed), isTrue);
    });

    test('une commande encore ouverte s\'encaisse', () {
      // Les deux états d'où part une clôture normale.
      expect(isAlreadySettled(SaleStatus.scheduled), isFalse);
      expect(isAlreadySettled(SaleStatus.processing), isFalse);
    });

    test('les états morts ne sont PAS traités ici, et c\'est voulu', () {
      // `cancelled`, `refused` et `refunded` n'ont aucune sortie vers
      // `completed` dans la table des transitions : `updateOrderStatus` les
      // refuse déjà avec son propre message. Les rejouer ici doublerait une
      // règle au lieu de la renforcer — et le jour où la table changerait, on
      // aurait deux vérités à tenir en miroir. On connaît la suite.
      expect(isAlreadySettled(SaleStatus.cancelled), isFalse);
      expect(isAlreadySettled(SaleStatus.refused), isFalse);
      expect(isAlreadySettled(SaleStatus.refunded), isFalse);
    });

    test('LA TABLE DES TRANSITIONS COUVRE BIEN CES TROIS ÉTATS', () {
      // L'invariant qui justifie le test précédent. S'il tombe, la garde
      // ci-dessus devient insuffisante et il faudra l'élargir.
      for (final dead in [
        SaleStatus.cancelled,
        SaleStatus.refused,
        SaleStatus.refunded,
      ]) {
        expect(
            SaleStatusTransitions.canTransition(dead, SaleStatus.completed),
            isFalse,
            reason: dead.name);
      }
    });

    test('et `completed → completed` reste accepté par la table', () {
      // On ne touche PAS à `canTransition` : il est partagé avec
      // l'e-commerce, et son `from == to` est la contrepartie de
      // l'idempotence voulue de `updateOrderStatus`. La garde est ailleurs.
      expect(
          SaleStatusTransitions.canTransition(
              SaleStatus.completed, SaleStatus.completed),
          isTrue);
    });
  });

  group('Ce que lit l\'opérateur', () {
    test('le refus porte un message rédigé, pas un code', () {
      const e = DejaEncaisseeException();
      expect(e.message, contains('déjà été encaissée'));
      expect(e.message, contains('autre appareil'));
      expect(e.code, 'deja_encaissee');
    });

    test('il dit que RIEN n\'a été écrit une seconde fois', () {
      // Le point qui compte pour quelqu'un debout en plein service : il doit
      // savoir qu'il n'a pas à défaire quoi que ce soit.
      const e = DejaEncaisseeException();
      expect(e.message, contains('Rien n\'a été enregistré'));
      expect(e.toString(), e.message);
    });
  });
}
