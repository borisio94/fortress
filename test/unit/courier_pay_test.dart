// La livraison était encaissée sans charge de livreur.
//
// C'était le dernier écart de la section 8 de la définition financière. Le
// client paie des frais, l'établissement les encaisse, un livreur est nommé —
// et RIEN ne dit ce qu'il reçoit. Ni recette, ni charge : deux flux réels,
// invisibles tous les deux.
//
// LE PLUS GRAVE N'EST PAS LE REPORTING, C'EST LA CAISSE. Le livreur de
// dépannage est payé en espèces, du tiroir, le soir même. `cashOut` ne le
// savait pas — il n'additionne que les dépenses du jour et les sorties du
// personnel. Chaque livraison ainsi payée apparaissait donc à la clôture
// aveugle comme un MANQUANT imputé au caissier. C'est le même défaut que les
// avances sur salaire et les heures supplémentaires payées le soir, refermé
// deux fois déjà.
//
// TROIS CAS COEXISTENT, et la règle doit les porter tous les trois :
//   * les frais reviennent en entier au livreur — le cas courant ;
//   * ils sont partagés, l'établissement garde la différence ;
//   * le livreur est un SALARIÉ, dont le coût est déjà dans la paie. Verser
//     en plus paierait la même course deux fois.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:fortress/core/services/daily_expense_service.dart';
import 'package:fortress/core/services/restaurant_order_service.dart';
import 'package:fortress/core/services/restaurant_reporting_service.dart';
import 'package:fortress/core/storage/hive_boxes.dart';
import 'package:fortress/features/caisse/domain/entities/sale_item.dart';
import 'package:fortress/features/dashboard/data/dashboard_providers.dart'
    show DashRange;
import 'package:fortress/features/restaurant/domain/courier_pay.dart';
const _untypedBoxes = [HiveBoxes.settings, HiveBoxes.cart];
const _mapBoxes = [
  HiveBoxes.offlineQueue,
  HiveBoxes.shops,
  HiveBoxes.products,
  HiveBoxes.clients,
  HiveBoxes.orders,
  HiveBoxes.stockLevels,
  HiveBoxes.notifications,
  HiveBoxes.restaurantTables,
  HiveBoxes.dailyMenuAvailability,
  HiveBoxes.ingredients,
  HiveBoxes.recipeIngredients,
  HiveBoxes.restaurantActivities,
  HiveBoxes.stockItems,
  HiveBoxes.fixedCharges,
  HiveBoxes.losses,
  HiveBoxes.employees,
  HiveBoxes.payroll,
  HiveBoxes.salaryAdvances,
  HiveBoxes.dailyExpenses,
];

final _now = DateTime.now();
final _today = DateTime(_now.year, _now.month, _now.day);
DashRange get _range => DashRange(
    _today.subtract(const Duration(days: 1)),
    _today.add(const Duration(days: 2)));

/// Une commande a livrer prise au comptoir, encaissee dans la foulee.
///
/// On passe par LE SERVICE, pas par une map fabriquee a la main : ce qu'on
/// veut prouver, c'est que le parcours reel ecrit la depense.
Future<void> _delivery(
  String shop, {
  required double fee,
  required double pay,
  bool payIsCash = true,
  bool staffCourier = false,
}) async {
  final order = await RestaurantOrderService.saveDeliveryOrder(
    shopId: shop,
    items: [
      const SaleItem(
        productId: 'p_plat',
        productName: 'Plat',
        quantity: 1,
        unitPrice: 5000,
      ),
    ],
    clientName: 'Client',
    address: 'Quartier',
    deliveryFee: fee,
    courierPay:
        courierPayDefault(deliveryFee: pay, courierIsStaff: staffCourier),
    courierPayIsCash: payIsCash,
    courier: staffCourier ? 'Salarie' : 'Voisin',
  );
  // Encaissee : sans cloture, aucune recette n'est comptee.
  final at = _now.toUtc().toIso8601String();
  final raw = Map<String, dynamic>.from(HiveBoxes.ordersBox.get(order.id)!);
  raw['status'] = 'completed';
  raw['completed_at'] = at;
  raw['created_at'] = at;
  await HiveBoxes.ordersBox.put(order.id, raw);
}

void main() {
  group('Ce qu\'on propose de verser', () {
    test('les frais en entier, pour un livreur de dépannage', () {
      expect(
          courierPayDefault(deliveryFee: 1000, courierIsStaff: false), 1000);
    });

    test('ZÉRO pour un salarié — son coût est déjà dans la paie', () {
      // LE test rouge, et le piège du lot. Laisser le champ pré-rempli sur un
      // salarié ferait payer la même course deux fois : une fois en espèces
      // le soir, une fois dans la paie à la quinzaine.
      expect(courierPayDefault(deliveryFee: 1000, courierIsStaff: true), 0);
    });

    test('sans frais, rien à verser', () {
      expect(courierPayDefault(deliveryFee: 0, courierIsStaff: false), 0);
    });
  });

  group('Quand une dépense est écrite', () {
    test('un versement réel en produit une', () {
      // C'est elle qui fait entrer le montant dans `cashOut` : le service de
      // clôture somme déjà `DailyExpenseService.cashOut`, qui filtre sur
      // `isCash`. Écrire la dépense SUFFIT à refermer le manquant.
      expect(courierPayNeedsExpense(700), isTrue);
    });

    test('un versement nul n\'en produit aucune', () {
      // Le salarié, ou la livraison offerte. Une dépense à zéro polluerait le
      // journal sans rien apprendre.
      expect(courierPayNeedsExpense(0), isFalse);
    });

    test('elle est une CHARGE, et pas un coût matière', () {
      // Payer un livreur n'achète pas d'ingrédient : le montant ne doit pas
      // entrer dans l'assiette répartie sur les plats vendus.
      expect(kCourierExpenseKind.isCharge, isTrue);
      expect(kCourierExpenseKind.isFoodCost, isFalse);
    });
  });

  group('Les frais entrent en recette', () {
    test('parce que la charge est enfin en face', () {
      // La section 2 disait « recette réelle, mais aucune ligne ne retranche
      // le coût du livreur. Dette ouverte : à intégrer avec sa charge, pas
      // seule. » La condition est remplie.
      expect(orderRevenueOf(itemsNet: 5000, deliveryFee: 1000), 6000);
    });

    test('une commande sans livraison ne change pas', () {
      expect(orderRevenueOf(itemsNet: 5000, deliveryFee: 0), 5000);
    });

    test('le bénéfice d\'une livraison est la DIFFÉRENCE', () {
      // Frais 1 000, livreur 700 : l'établissement gagne 300. Avant ce lot il
      // gagnait 0 au bilan tout en encaissant 1 000 et en sortant 700.
      const fee = 1000.0, paid = 700.0;
      final revenue = orderRevenueOf(itemsNet: 0, deliveryFee: fee);
      expect(revenue - paid, 300);
    });
  });

  // ══ LE PARCOURS RÉEL, sur un Hive ouvert ═══════════════════════════════
  //
  // Les règles ci-dessus sont des fonctions pures : elles disent ce qu'il
  // FAUDRAIT faire. Ce qui suit vérifie que le parcours le fait — prendre une
  // commande à livrer au comptoir écrit bien la dépense, et les frais font
  // bien monter le chiffre d'affaires.
  group('De la prise de commande à la caisse', () {
    late Directory tmp;

    setUpAll(() async {
      tmp = Directory.systemTemp.createTempSync('fortress_courier_pay');
      Hive.init(tmp.path);
      for (final b in _untypedBoxes) {
        await Hive.openBox(b);
      }
      for (final b in _mapBoxes) {
        await Hive.openBox<Map>(b);
      }
    });

    tearDownAll(() async {
      await Hive.close();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('UN VERSEMENT EN ESPÈCES APPARAÎT DANS cashOut', () async {
      // LE test du lot. `cashOut` est ce que la clôture de caisse retranche du
      // fond attendu ; tant que le versement n'y figurait pas, le voisin payé
      // 700 F du tiroir devenait un manquant de 700 F imputé au caissier.
      const shop = 'shop_liv';
      await _delivery(shop, fee: 1000, pay: 700);
      expect(DailyExpenseService.cashOut(shop, from: _today, to: _today), 700);
    });

    test('la dépense est une CHARGE de transport, pas un achat de matière',
        () {
      // Sinon les 700 F entreraient dans l'assiette répartie sur les plats
      // vendus, et feraient monter le food cost d'un coût qui n'a rien de
      // matière.
      const shop = 'shop_liv';
      final lines = DailyExpenseService.forShop(shop);
      expect(lines, hasLength(1));
      expect(lines.first.kind, kCourierExpenseKind);
      expect(lines.first.isFoodCost, isFalse);
    });

    test('LE CA MONTE DE 1 000 SANS QU\'AUCUNE VENTE N\'AIT CHANGÉ', () {
      // Un plat à 5 000 et des frais de 1 000. Avant ce lot le bilan lisait
      // 5 000 ; il lit 6 000, pour exactement les mêmes articles vendus.
      const shop = 'shop_liv';
      final r = RestaurantReportingService.build(shop, _range);
      expect(r.foodRevenue, closeTo(5000, 0.01));
      expect(r.deliveryRevenue, closeTo(1000, 0.01));
      expect(r.revenue, closeTo(6000, 0.01));
    });

    test('un versement HORS ESPÈCES ne touche pas le tiroir', () async {
      // Mobile Money, virement, « je te paierai demain » : c'est une charge,
      // mais rien n'est sorti de la caisse ce soir. La retrancher du fond
      // attendu créerait un EXCÉDENT aussi faux que le manquant d'avant.
      const shop = 'shop_mm';
      await _delivery(shop, fee: 1000, pay: 700, payIsCash: false);
      expect(DailyExpenseService.cashOut(shop, from: _today, to: _today), 0);
      expect(DailyExpenseService.forShop(shop), hasLength(1));
    });

    test('un livreur SALARIÉ n\'écrit aucune dépense', () async {
      // Son coût est déjà dans la paie. Verser en plus paierait la même
      // course deux fois — et la recette des frais, elle, entre quand même.
      const shop = 'shop_salarie';
      await _delivery(shop, fee: 1000, pay: 1000, staffCourier: true);
      expect(DailyExpenseService.forShop(shop), isEmpty);
      final r = RestaurantReportingService.build(shop, _range);
      expect(r.deliveryRevenue, closeTo(1000, 0.01));
    });
  });
}
