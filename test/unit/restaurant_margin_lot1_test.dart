// Lot 1 de l'audit des marges restaurant — tests écrits AVANT le correctif.
//
// Ils appellent le VRAI moteur (`RestaurantReportingService.build`,
// `ServiceIncidentService.reportUnpaid`) sur un Hive réel ouvert dans un
// dossier temporaire. Les tests existants ne couvraient que les getters d'un
// rapport construit à la main : ils restaient verts quel que soit le calcul.
//
// Décisions verrouillées ici (2026-09-15) :
//   n°4 — CA = articles − remise de l'addition (+ TVA). Consignes et livraison
//         HORS CA. La remise est ventilée au prorata des lignes : la somme des
//         secteurs égale le CA.
//   n°1 — un départ sans payer ne coûte QUE la matière des tournées envoyées
//         en cuisine.
//   n°2 — voie (b) : une perte de matière est RETIRÉE de l'assiette à
//         répartir. Les assiettes perdues comptent comme des parts ; un écart
//         d'inventaire est retiré des achats de son ingrédient, plafonné à ce
//         qui a été acheté. Identité : coût matières + pertes = achats.
//
// FORMAT PROPOSÉ d'une perte de matière (map Hive / ligne `losses`) :
//   'items'         : [{'product_id': …, 'quantity': …}]  assiettes perdues
//   'ingredient_id' : 'ig_…'                               écart d'inventaire
// Le montant `amount` stocké reste l'estimation affichée à la déclaration ;
// le bilan le RECALCULE sur la période.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:fortress/core/services/restaurant_reporting_service.dart';
import 'package:fortress/core/services/service_incident_service.dart';
import 'package:fortress/core/storage/hive_boxes.dart';
import 'package:fortress/features/caisse/domain/entities/sale.dart';
import 'package:fortress/features/caisse/domain/entities/sale_item.dart';
import 'package:fortress/features/dashboard/data/dashboard_providers.dart'
    show DashRange;
import 'package:fortress/features/restaurant/domain/entities/daily_expense.dart';
import 'package:fortress/features/restaurant/domain/entities/ingredient.dart';
import 'package:fortress/features/restaurant/domain/entities/recipe_ingredient.dart';

// ── Boîtes lues ou écrites par le bilan et les incidents ──────────────────
const _untypedBoxes = [HiveBoxes.settings, HiveBoxes.cart];
const _mapBoxes = [
  HiveBoxes.offlineQueue,
  HiveBoxes.shops,
  HiveBoxes.users,
  HiveBoxes.products,
  HiveBoxes.clients,
  HiveBoxes.orders,
  HiveBoxes.stockLevels,
  HiveBoxes.stockMovements,
  HiveBoxes.notifications,
  HiveBoxes.restaurantTables,
  HiveBoxes.dailyMenuAvailability,
  HiveBoxes.ingredients,
  HiveBoxes.recipeIngredients,
  HiveBoxes.restaurantActivities,
  HiveBoxes.stockItems,
  HiveBoxes.fixedCharges,
  HiveBoxes.losses,
  HiveBoxes.payments,
  HiveBoxes.employees,
  HiveBoxes.payroll,
  HiveBoxes.salaryAdvances,
  HiveBoxes.dailyExpenses,
];

final _now = DateTime.now();
final _today = DateTime(_now.year, _now.month, _now.day);

/// Hier → après-demain : englobe tout ce qui est daté d'aujourd'hui.
DashRange get _range => DashRange(
    _today.subtract(const Duration(days: 1)),
    _today.add(const Duration(days: 2)));

// ── Fabriques de données ───────────────────────────────────────────────────

Future<void> _product(String shop, String id,
    {String? activityId, double priceBuy = 0}) async {
  await HiveBoxes.productsBox.put(id, {
    'id': id,
    'store_id': shop,
    'name': id,
    'price_buy': priceBuy,
    'price_sell_pos': 0,
    'activity_id': activityId,
  });
}

Future<void> _completedOrder(
  String shop,
  String id, {
  required List<Map<String, dynamic>> items,
  double discountAmount = 0,
  double taxRate = 0,
  List<Map<String, dynamic>> fees = const [],
  double? deliveryPrice,
}) async {
  final at = _now.toUtc().toIso8601String();
  await HiveBoxes.ordersBox.put(id, {
    'id': id,
    'shop_id': shop,
    'status': 'completed',
    'created_at': at,
    'completed_at': at,
    'payment_method': 'cash',
    'items': items,
    'discount_amount': discountAmount,
    'tax_rate': taxRate,
    'fees': fees,
    'delivery_price': deliveryPrice,
  });
}

Map<String, dynamic> _line(String productId, int qty, double price) =>
    {'product_id': productId, 'quantity': qty, 'unit_price': price};

Future<void> _ingredient(String shop, String id,
    {String method = Ingredient.costRepartition,
    String unit = 'kg',
    int costPerUnit = 0}) async {
  await HiveBoxes.ingredientsBox.put(
      id,
      Ingredient(
        id: id,
        shopId: shop,
        name: id,
        unit: unit,
        costPerUnit: costPerUnit,
        costMethod: method,
        createdAt: _now,
      ).toMap());
}

Future<void> _link(String shop, String productId, String ingredientId,
    {double quantity = 0, String unit = ''}) async {
  final id = 'ri_${productId}_$ingredientId';
  await HiveBoxes.recipeIngredientsBox.put(
      id,
      RecipeIngredient(
        id: id,
        shopId: shop,
        productId: productId,
        ingredientId: ingredientId,
        quantity: quantity,
        unit: unit,
        quantityConfirmed: quantity > 0,
        createdAt: _now,
      ).toMap());
}

Future<void> _purchase(String shop, String ingredientId, int amount) async {
  final id = 'de_$ingredientId';
  await HiveBoxes.dailyExpensesBox.put(
      id,
      DailyExpense(
        id: id,
        shopId: shop,
        description: 'achat $ingredientId',
        amount: amount,
        category: ExpenseKind.achatMarche.key,
        ingredientId: ingredientId,
        expenseDate: _today,
        createdAt: _now,
      ).toMap());
}

Future<void> _loss(
  String shop,
  String id, {
  required int amount,
  required String category,
  List<Map<String, dynamic>>? items,
  String? ingredientId,
}) async {
  await HiveBoxes.lossesBox.put(id, {
    'schema_version': 1,
    'id': id,
    'shop_id': shop,
    'description': id,
    'amount': amount,
    'category': category,
    'origin': '',
    'date': DailyExpense.dayKey(_today),
    'created_at': _now.toUtc().toIso8601String(),
    if (items != null) 'items': items,
    if (ingredientId != null) 'ingredient_id': ingredientId,
  });
}

Sale _openRound(String shop, String id,
        {required bool sent, required int qty, required String productId}) =>
    Sale(
      id: id,
      shopId: shop,
      items: [
        SaleItem(
            productId: productId,
            productName: productId,
            unitPrice: 5000,
            quantity: qty),
      ],
      paymentMethod: PaymentMethod.cash,
      status: SaleStatus.scheduled,
      createdAt: _now,
      orderType: 'dine_in',
      tabLabel: 'Compte 1',
      sentToKitchen: sent,
    );

void main() {
  late Directory tmp;

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('fortress_margin_lot1');
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

  // ══ n°4 — remise de l'addition, consignes, ventilation ══════════════════
  group('n°4 — chiffre d\'affaires', () {
    const shop = 'shop_n4_discount';

    setUpAll(() async {
      await _product(shop, 'p_plat', activityId: 'ra_cuisine');
      await _product(shop, 'p_biere', activityId: 'ra_bar');
      // 2 × 5 000 (cuisine) + 1 × 10 000 (bar) = 20 000 d'articles,
      // remise 4 000, consigne 1 000, livraison 1 500.
      await _completedOrder(shop, 'o_n4',
          items: [_line('p_plat', 2, 5000), _line('p_biere', 1, 10000)],
          discountAmount: 4000,
          fees: [
            {'id': 'fee_1', 'label': 'Consigne', 'amount': 1000}
          ],
          deliveryPrice: 1500);
    });

    test('la remise de l\'addition sort des ventes (20 000 − 4 000 = 16 000)',
        () {
      // Le chiffre des PLATS. Ce test disait « du CA » jusqu'au 21/09/2026 :
      // depuis, le CA porte aussi la livraison, et c'est `foodRevenue` qui
      // isole ce que les assiettes ont rapporté.
      final r = RestaurantReportingService.build(shop, _range);
      expect(r.foodRevenue, closeTo(16000, 0.01));
    });

    test('la consigne n\'entre pas dans le CA', () {
      // Une caution rendue au client n'est pas un produit, et son
      // remboursement est exclu du bilan : elle se neutralise des deux côtés.
      // Inchangé par ce lot.
      final r = RestaurantReportingService.build(shop, _range);
      expect(r.revenue, isNot(closeTo(16000 + 1000, 0.01)));
    });

    test('LA LIVRAISON, ELLE, ENTRE DANS LE CA (16 000 + 1 500)', () {
      // Le renversement du 21/09/2026. Elle en était exclue tant qu'aucune
      // ligne ne portait le coût du livreur ; ce coût est écrit désormais, au
      // moment de la prise de commande, donc la recette peut entrer.
      //
      // Elle entre BRUTE : la remise de 4 000 porte sur les plats, pas sur la
      // course, exactement comme `Sale.total` l'additionne.
      final r = RestaurantReportingService.build(shop, _range);
      expect(r.revenue, closeTo(17500, 0.01));
      expect(r.deliveryRevenue, closeTo(1500, 0.01));
    });

    test('mais elle reste HORS du dénominateur du food cost', () {
      // Sans quoi le taux se diluerait dans des recettes qui ne portent
      // aucune matière — le défaut même que `costedRevenue` avait corrigé
      // pour les boissons sans coût connu.
      final r = RestaurantReportingService.build(shop, _range);
      expect(r.foodRevenue, closeTo(r.revenue - r.deliveryRevenue, 0.01));
      expect(r.foodRevenue, closeTo(16000, 0.01));
    });

    test('remise ventilée au prorata : cuisine 8 000, bar 8 000', () {
      final r = RestaurantReportingService.build(shop, _range);
      final bySector = {for (final s in r.sectors) s.activityId: s.revenue};
      expect(bySector['ra_cuisine'], closeTo(8000, 0.01));
      expect(bySector['ra_bar'], closeTo(8000, 0.01));
    });

    test('somme des secteurs = ventes de plats, somme des buckets = CA', () {
      // DEUX INVARIANTS DISTINCTS depuis le 21/09/2026, et c'est voulu : une
      // course n'appartient à aucune activité. La ranger dans « Sans secteur »
      // y ferait apparaître un montant que rien ne permet de rattacher — le
      // gérant chercherait indéfiniment un plat manquant qui n'existe pas.
      final r = RestaurantReportingService.build(shop, _range);
      final sectors = r.sectors.fold<double>(0, (s, l) => s + l.revenue);
      final buckets = r.revenueSeries.fold<double>(0, (s, v) => s + v);
      expect(sectors, closeTo(r.foodRevenue, 0.01));
      expect(buckets, closeTo(r.revenue, 0.01));
    });

    // GARDE-FOU POUR UN CHEMIN INERTE : `tax_rate` n'est JAMAIS renseigné
    // côté restaurant, il vaut 0 sur toutes les commandes. Ce test ne prouve
    // PAS que la TVA est active — il verrouille la formule pour le jour où un
    // taux sera saisi.
    test('[garde-fou TVA inactive] le jour où un taux existera, il suivra '
        'Sale.total : (20 000 − 4 000) × 1,10 = 17 600', () async {
      const taxShop = 'shop_n4_tax';
      await _product(taxShop, 'p_plat_t', activityId: 'ra_cuisine');
      await _product(taxShop, 'p_biere_t', activityId: 'ra_bar');
      await _completedOrder(taxShop, 'o_n4_tax',
          items: [_line('p_plat_t', 2, 5000), _line('p_biere_t', 1, 10000)],
          discountAmount: 4000,
          taxRate: 10);
      final r = RestaurantReportingService.build(taxShop, _range);
      expect(r.revenue, closeTo(17600, 0.01));
    });
  });

  // ══ n°2 — voie (b) : retrait de l'assiette ══════════════════════════════
  group('n°2 — une perte de matière est retirée de l\'assiette', () {
    test('assiettes perdues : 20 000 F de poulet, 98 vendues, 2 jetées', () async {
      const shop = 'shop_n2_plates';
      await _product(shop, 'p_dg');
      await _ingredient(shop, 'ig_poulet');
      await _link(shop, 'p_dg', 'ig_poulet');
      await _purchase(shop, 'ig_poulet', 20000);
      await _completedOrder(shop, 'o_n2', items: [_line('p_dg', 98, 3000)]);
      await _loss(shop, 'ls_n2',
          amount: 400,
          category: 'plat_mal_fait',
          items: [
            {'product_id': 'p_dg', 'quantity': 2}
          ]);

      final r = RestaurantReportingService.build(shop, _range);
      // 100 parts → 200 F la part.
      expect(r.materialCost, closeTo(19600, 0.5),
          reason: 'coût des 98 assiettes vendues, gâchis exclu');
      expect(r.losses, 400);
      expect(r.foodCost + r.losses, closeTo(20000, 0.5),
          reason: 'matière comptée une seule fois');
    });

    test('écart d\'inventaire : retiré des achats de son ingrédient', () async {
      const shop = 'shop_n2_inventory';
      await _product(shop, 'p_dg');
      await _ingredient(shop, 'ig_poulet');
      await _link(shop, 'p_dg', 'ig_poulet');
      await _purchase(shop, 'ig_poulet', 20000);
      await _completedOrder(shop, 'o_n2i', items: [_line('p_dg', 100, 3000)]);
      await _loss(shop, 'ls_n2i',
          amount: 1000, category: 'ecart_inventaire', ingredientId: 'ig_poulet');

      final r = RestaurantReportingService.build(shop, _range);
      expect(r.materialCost, closeTo(19000, 0.5));
      expect(r.losses, 1000);
      expect(r.foodCost + r.losses, closeTo(20000, 0.5));
    });

    test('écart supérieur aux achats : plafonné, jamais de coût négatif',
        () async {
      const shop = 'shop_n2_cap';
      await _product(shop, 'p_dg');
      await _ingredient(shop, 'ig_poulet');
      await _link(shop, 'p_dg', 'ig_poulet');
      await _purchase(shop, 'ig_poulet', 20000);
      await _completedOrder(shop, 'o_n2c', items: [_line('p_dg', 100, 3000)]);
      await _loss(shop, 'ls_n2c',
          amount: 25000, category: 'ecart_inventaire', ingredientId: 'ig_poulet');

      final r = RestaurantReportingService.build(shop, _range);
      expect(r.materialCost, greaterThanOrEqualTo(0));
      expect(r.losses, 20000, reason: 'plafonné à l\'assiette disponible');
      expect(r.foodCost + r.losses, closeTo(20000, 0.5));
    });
  });

  // ══ 4e test — identité sur un jeu mixte répartition + fiche technique ═══
  group('identité coût matières + pertes = achats (répartition + fiche)', () {
    const shop = 'shop_identity_mixed';

    setUpAll(() async {
      await _product(shop, 'p_dg');
      // Poulet en RÉPARTITION : 20 000 F achetés.
      await _ingredient(shop, 'ig_poulet');
      await _link(shop, 'p_dg', 'ig_poulet');
      await _purchase(shop, 'ig_poulet', 20000);
      // Riz en FICHE TECHNIQUE : 0,25 kg par portion à 1 000 F/kg. Achats
      // cohérents avec la consommation : 100 assiettes × 250 F = 25 000 F.
      await _ingredient(shop, 'ig_riz',
          method: Ingredient.costSheet, unit: 'kg', costPerUnit: 1000);
      await _link(shop, 'p_dg', 'ig_riz', quantity: 0.25, unit: 'kg');
      await _purchase(shop, 'ig_riz', 25000);
      // 98 vendues, 2 perdues → 200 (poulet) + 250 (riz) = 450 F l'assiette.
      await _completedOrder(shop, 'o_id', items: [_line('p_dg', 98, 3000)]);
      await _loss(shop, 'ls_id',
          amount: 900,
          category: 'plat_mal_fait',
          items: [
            {'product_id': 'p_dg', 'quantity': 2}
          ]);
    });

    test('coût théorique + pertes = achats', () {
      final r = RestaurantReportingService.build(shop, _range);
      expect(r.materialCost, closeTo(98 * 450, 0.5));
      expect(r.losses, 900);
      expect(r.materialCost + r.losses, closeTo(45000, 0.5));
    });

    test('food cost retenu + pertes = achats', () {
      final r = RestaurantReportingService.build(shop, _range);
      expect(r.foodCost + r.losses, closeTo(45000, 0.5));
    });
  });

  // ══ Page Pertes — UN SEUL TOTAL, celui du bilan (décision A1) ═══════════
  //
  // La page Pertes lit les lignes du bilan de la période du tableau de bord.
  // Le montant saisi à la déclaration reste une estimation : visible, jamais
  // sommé.
  group('page Pertes — lignes recalculées = total du bilan', () {
    const shop = 'shop_loss_lines';

    setUpAll(() async {
      await _product(shop, 'p_dg');
      await _ingredient(shop, 'ig_poulet');
      await _link(shop, 'p_dg', 'ig_poulet');
      await _purchase(shop, 'ig_poulet', 20000);
      await _completedOrder(shop, 'o_ll', items: [_line('p_dg', 97, 3000)]);
      // Estimation saisie volontairement FAUSSE (999) : la ligne doit
      // afficher la valeur recalculée, pas elle.
      await _loss(shop, 'ls_plates',
          amount: 999,
          category: 'plat_mal_fait',
          items: [
            {'product_id': 'p_dg', 'quantity': 2}
          ]);
      await _loss(shop, 'ls_inventory',
          amount: 200, category: 'ecart_inventaire', ingredientId: 'ig_poulet');
      await _loss(shop, 'ls_casse', amount: 1500, category: 'casse');
    });

    test('chaque perte de la période a sa ligne', () {
      final r = RestaurantReportingService.build(shop, _range);
      expect(r.lossLines.map((l) => l.loss.id).toSet(),
          {'ls_plates', 'ls_inventory', 'ls_casse'});
    });

    test('valeurs recalculées : assiettes, inventaire, charge', () {
      final r = RestaurantReportingService.build(shop, _range);
      final byId = {for (final l in r.lossLines) l.loss.id: l};
      // (20 000 − 200 retirés) ÷ (97 + 2 parts) = 200 F la part.
      expect(byId['ls_plates']!.value, closeTo(400, 0.5));
      expect(byId['ls_plates']!.isRecalculated, isTrue);
      expect(byId['ls_inventory']!.value, closeTo(200, 0.5));
      expect(byId['ls_inventory']!.isRecalculated, isTrue);
      // Non rattachée : une charge, à son montant saisi.
      expect(byId['ls_casse']!.value, 1500);
      expect(byId['ls_casse']!.isRecalculated, isFalse);
    });

    test('somme des lignes = total du bilan (un seul total)', () {
      final r = RestaurantReportingService.build(shop, _range);
      final sum = r.lossLines.fold<double>(0, (s, l) => s + l.value);
      expect(sum.round(), r.losses);
      expect(r.losses, 2100);
    });

    test('une perte hors période n\'a pas de ligne', () async {
      const other = 'shop_loss_lines_outside';
      await HiveBoxes.lossesBox.put('ls_old', {
        'schema_version': 2,
        'id': 'ls_old',
        'shop_id': other,
        'description': 'ancienne',
        'amount': 500,
        'category': 'casse',
        'origin': '',
        'date': DailyExpense.dayKey(_today.subtract(const Duration(days: 60))),
        'created_at': _now.toUtc().toIso8601String(),
      });
      final r = RestaurantReportingService.build(other, _range);
      expect(r.lossLines, isEmpty);
      expect(r.losses, 0);
    });
  });

  // ══ n°1 — départ sans payer ═════════════════════════════════════════════
  group('n°1 — départ sans payer', () {
    Future<void> seedKitchen(String shop) async {
      await _product(shop, 'p_dg');
      await _ingredient(shop, 'ig_poulet');
      await _link(shop, 'p_dg', 'ig_poulet');
      await _purchase(shop, 'ig_poulet', 20000);
      await _completedOrder(shop, 'o_sold_$shop',
          items: [_line('p_dg', 98, 5000)]);
    }

    test('perte = matière des tournées ENVOYÉES, pas le total de l\'addition',
        () async {
      const shop = 'shop_n1_mixed';
      await seedKitchen(shop);
      final sent = _openRound(shop, 'o_sent', sent: true, qty: 2, productId: 'p_dg');
      final notSent =
          _openRound(shop, 'o_not_sent', sent: false, qty: 1, productId: 'p_dg');

      await ServiceIncidentService.reportUnpaid(
          shopId: shop, orders: [sent, notSent], origin: 'Table 1');

      final r = RestaurantReportingService.build(shop, _range);
      // 98 vendues + 2 envoyées-perdues = 100 parts → 200 F la part.
      expect(r.revenue, closeTo(98 * 5000, 0.01),
          reason: 'l\'addition impayée n\'a jamais été du CA');
      expect(r.losses, 400,
          reason: 'la matière de 2 assiettes, pas 15 000 F d\'addition');
      expect(r.foodCost + r.losses, closeTo(20000, 0.5));

      final stored = HiveBoxes.lossesBox.values
          .where((m) => m['shop_id'] == shop)
          .toList();
      expect(stored, hasLength(1));
      expect(stored.single['items'], [
        {'product_id': 'p_dg', 'quantity': 2}
      ], reason: 'seule la tournée envoyée est tracée');
    });

    test('rien n\'est parti en cuisine : aucune perte', () async {
      const shop = 'shop_n1_nothing_sent';
      await seedKitchen(shop);
      final notSent =
          _openRound(shop, 'o_ns_only', sent: false, qty: 3, productId: 'p_dg');

      await ServiceIncidentService.reportUnpaid(
          shopId: shop, orders: [notSent], origin: 'Table 2');

      final r = RestaurantReportingService.build(shop, _range);
      expect(r.losses, 0);
      expect(r.materialCost + r.losses, closeTo(20000, 0.5));
    });
  });
}
