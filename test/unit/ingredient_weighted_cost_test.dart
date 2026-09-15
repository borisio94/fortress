// Tests du coût moyen pondéré d'un ingrédient à la réception.
//
// POURQUOI ce calcul existe : sans lui, le prix se saisissait DEUX fois — à la
// réception, et dans la fiche de l'ingrédient. Deux valeurs à tenir à jour
// manuellement finissent toujours par diverger, et c'est celle de la fiche qui
// chiffre les pertes d'inventaire.
//
//         valeur du stock existant + montant payé
//         ───────────────────────────────────────
//           quantité existante + quantité reçue

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/services/ingredient_service.dart';

int cost({
  double currentQty = 0,
  int currentUnitCost = 0,
  double receivedQty = 0,
  int amountPaid = 0,
}) =>
    IngredientService.weightedUnitCost(
      currentQty: currentQty,
      currentUnitCost: currentUnitCost,
      receivedQty: receivedQty,
      amountPaid: amountPaid,
    );

void main() {
  group('Moyenne pondérée', () {
    test('l\'exemple de référence tombe juste', () {
      // 2 tas valorisés 750 F pièce (1 500 F), on reçoit 3 tas payés 2 400 F.
      // (1 500 + 2 400) ÷ 5 = 780 F/tas.
      expect(
          cost(
              currentQty: 2,
              currentUnitCost: 750,
              receivedQty: 3,
              amountPaid: 2400),
          780);
    });

    test('la première réception FIXE le coût', () {
      // Ingrédient créé sans prix : rien à moyenner, l'achat fait foi.
      expect(cost(receivedQty: 4, amountPaid: 6000), 1500);
    });

    test('un rachat au même prix ne bouge pas le coût', () {
      expect(
          cost(
              currentQty: 5,
              currentUnitCost: 1000,
              receivedQty: 5,
              amountPaid: 5000),
          1000);
    });

    test('un rachat plus cher tire le coût vers le haut, sans l\'atteindre', () {
      // 10 kg à 1 000 F + 10 kg à 2 000 F → 1 500 F, pas 2 000 F.
      final c = cost(
          currentQty: 10,
          currentUnitCost: 1000,
          receivedQty: 10,
          amountPaid: 20000);
      expect(c, 1500);
      expect(c, greaterThan(1000));
      expect(c, lessThan(2000));
    });

    test('un gros stock existant amortit un petit achat cher', () {
      // 100 kg à 1 000 F + 1 kg à 5 000 F → 1 040 F.
      expect(
          cost(
              currentQty: 100,
              currentUnitCost: 1000,
              receivedQty: 1,
              amountPaid: 5000),
          1040);
    });

    test('le résultat est arrondi à l\'entier', () {
      // (0 + 1 000) ÷ 3 = 333,33…
      expect(cost(receivedQty: 3, amountPaid: 1000), 333);
    });
  });

  group('Ce qui NE doit PAS diluer le coût', () {
    test('un montant à zéro laisse le coût inchangé', () {
      // Zéro ne veut pas dire « gratuit » mais « montant non renseigné ». Le
      // diluer ferait baisser le coût à chaque réception mal saisie, et
      // sous-évaluerait silencieusement les pertes d'inventaire.
      expect(
          cost(currentQty: 2, currentUnitCost: 750, receivedQty: 10),
          750);
    });

    test('un montant négatif laisse le coût inchangé', () {
      expect(
          cost(
              currentQty: 2,
              currentUnitCost: 750,
              receivedQty: 10,
              amountPaid: -500),
          750);
    });

    test('une quantité reçue nulle laisse le coût inchangé', () {
      expect(
          cost(currentQty: 2, currentUnitCost: 750, amountPaid: 3000), 750);
    });
  });

  group('Cas limites', () {
    test('un stock existant négatif est traité comme vide', () {
      // Ne devrait pas arriver (le décrément plafonne à 0), mais une donnée
      // corrompue ne doit pas produire un coût négatif.
      final c = cost(
          currentQty: -5,
          currentUnitCost: 1000,
          receivedQty: 2,
          amountPaid: 4000);
      expect(c, 2000);
      expect(c, greaterThan(0));
    });

    test('aucun stock et aucun coût : l\'achat fait foi', () {
      expect(cost(receivedQty: 1, amountPaid: 750), 750);
    });

    test('le coût ne devient jamais négatif', () {
      expect(
          cost(
              currentQty: 1,
              currentUnitCost: 0,
              receivedQty: 1,
              amountPaid: 1),
          greaterThanOrEqualTo(0));
    });
  });
}
