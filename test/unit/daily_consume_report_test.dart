// Le décompte du jour perdait ce qu'il n'arrivait pas à retirer.
//
// `DailyMenuService.consume` rabotait à zéro sans le dire :
//
//     final next = cur.count! - qty;
//     await _write(…, count: next < 0 ? 0 : next);
//
// Trois portions restantes, une commande de cinq → on écrivait 0, et personne
// n'apprenait qu'on en avait vendu deux de trop. Le cas n'est pas théorique :
// `_addToCart` vérifie que le plat est disponible (décompte > 0), PAS que la
// quantité demandée tient, et deux serveurs peuvent commander en même temps.
//
// `_write` avalait par ailleurs un refus de Hive dans un `debugPrint` : le
// décrément était alors perdu en entier, sans trace.
//
// CE QUE L'AUDIT DISAIT, ET QUI ÉTAIT FAUX : « l'exception est avalée ». Il
// n'y a aucune exception. `read` et `_write` ont chacun leur `try/catch` et ne
// lèvent jamais, donc `consume` et `consumeForOrder` non plus — le `try/catch`
// qui entourait l'appel dans `RestaurantOrderService` était du code mort. La
// conclusion tenait (le serveur ne voit rien), le mécanisme était ailleurs.
//
// Ces tests portent sur l'ARITHMÉTIQUE, vérifiable sans Hive : c'est elle qui
// perdait l'information.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/services/daily_menu_service.dart';
import 'package:fortress/features/caisse/domain/entities/sale_item.dart';

SaleItem _line(String id, String name) =>
    SaleItem(productId: id, productName: name, quantity: 1, unitPrice: 0);

void main() {
  group('Ce qui manque au décompte', () {
    test('IL MANQUE DEUX PORTIONS QUAND ON EN VEND CINQ SUR TROIS', () {
      // LE test de ce lot. C'est exactement ce que le rabot effaçait.
      expect(shortfallOf(count: 3, qty: 5), 2);
    });

    test('rien ne manque quand le décompte suffit', () {
      expect(shortfallOf(count: 5, qty: 3), 0);
      expect(shortfallOf(count: 3, qty: 3), 0);
    });

    test('un décompte déjà à zéro manque tout ce qu\'on lui demande', () {
      // Le pire cas, et le plus parlant : le plat était épuisé, la vente est
      // passée quand même. Avant, on réécrivait 0 sur 0, sans un mot.
      expect(shortfallOf(count: 0, qty: 4), 4);
    });

    test('SANS LIMITE, IL NE MANQUE JAMAIS RIEN', () {
      // `count == null` = aucune limite fixée. Le plat ne décrémente pas, donc
      // il ne peut rien manquer. Rapporter un dépassement ici ferait crier
      // l'application sur toute une carte qu'on n'a jamais décomptée.
      expect(shortfallOf(count: null, qty: 99), 0);
      expect(shortfallOf(count: null, qty: 0), 0);
    });

    test('une quantité nulle ne manque rien', () {
      expect(shortfallOf(count: 0, qty: 0), 0);
      expect(shortfallOf(count: 2, qty: 0), 0);
    });
  });

  group('Le bilan d\'une commande', () {
    test('un bilan propre ne dit rien', () {
      expect(DailyConsumeReport.clean.isClean, isTrue);
      expect(DailyConsumeReport.clean.totalOversold, 0);
    });

    test('UN DÉPASSEMENT REND LE BILAN NON PROPRE', () {
      const r = DailyConsumeReport(
          oversold: <String, int>{'p_riz': 2}, allStored: true);
      expect(r.isClean, isFalse);
      expect(r.totalOversold, 2);
    });

    test('une écriture perdue le rend non propre AUSSI', () {
      // Les deux pertes sont distinctes et comptent toutes les deux : un
      // décrément que Hive a refusé est invisible au même titre qu'un
      // dépassement, et c'est le défaut le plus ancien des deux.
      const r = DailyConsumeReport(oversold: <String, int>{}, allStored: false);
      expect(r.isClean, isFalse);
    });

    test('le total additionne tous les plats', () {
      const r = DailyConsumeReport(
          oversold: <String, int>{'p_riz': 2, 'p_jus': 1, 'p_eau': 3},
          allStored: true);
      expect(r.totalOversold, 6);
    });
  });

  group('Ce que le serveur lit', () {
    final items = [_line('p_riz', 'Riz sauté'), _line('p_jus', 'Jus de bissap')];

    test('un bilan propre ne dit RIEN', () {
      // Le cas courant. Une alerte à chaque encaissement ne serait plus une
      // alerte, et on apprendrait à la balayer sans la lire.
      expect(oversoldMessage(DailyConsumeReport.clean, items), isNull);
    });

    test('LE PLAT EST NOMMÉ, pas identifié', () {
      // `oversold` est indexé par identifiant produit. Afficher « p_riz : 2 »
      // à quelqu'un qui tient un plateau ne lui apprend rien.
      const r =
          DailyConsumeReport(oversold: {'p_riz': 2}, allStored: true);
      final msg = oversoldMessage(r, items)!;
      expect(msg, contains('Riz sauté'));
      expect(msg, isNot(contains('p_riz')));
    });

    test('le singulier et le pluriel sont tenus', () {
      expect(
          oversoldMessage(
              const DailyConsumeReport(oversold: {'p_riz': 1}, allStored: true),
              items)!,
          startsWith('1 portion vendue'));
      expect(
          oversoldMessage(
              const DailyConsumeReport(oversold: {'p_riz': 3}, allStored: true),
              items)!,
          startsWith('3 portions vendues'));
    });

    test('plusieurs plats sont tous nommés', () {
      final msg = oversoldMessage(
          const DailyConsumeReport(
              oversold: {'p_riz': 2, 'p_jus': 1}, allStored: true),
          items)!;
      expect(msg, contains('Riz sauté'));
      expect(msg, contains('Jus de bissap'));
      expect(msg, startsWith('3 portions'));
    });

    test('UNE ÉCRITURE PERDUE EST UNE AUTRE PHRASE', () {
      // Les deux pertes n'appellent pas le même geste : un dépassement envoie
      // vérifier la réserve, une écriture refusée dit que le décompte de la
      // journée entière n'est plus fiable. Les confondre enverrait compter des
      // portions dans un cas où il n'y a rien à compter.
      final msg = oversoldMessage(
          const DailyConsumeReport(oversold: {}, allStored: false), items)!;
      expect(msg, contains('non enregistré'));
      expect(msg, isNot(contains('portion')));
    });

    test('un plat absent des lignes retombe sur son identifiant', () {
      // Repli, pas exception : mieux vaut un identifiant illisible qu'une
      // alerte qui plante au moment où elle doit prévenir.
      final msg = oversoldMessage(
          const DailyConsumeReport(oversold: {'p_inconnu': 1}, allStored: true),
          items)!;
      expect(msg, contains('p_inconnu'));
    });
  });
}
