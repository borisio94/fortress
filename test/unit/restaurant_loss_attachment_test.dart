// Rattachement obligatoire des pertes de matière — suite du lot 1 de l'audit
// des marges restaurant. Tests écrits AVANT le correctif.
//
// Décisions (2026-09-15) :
//   MATIÈRE — rattachement OBLIGATOIRE (des assiettes, ou un ingrédient) :
//     reste_invendu · plat_mal_fait · non_paye · ecart_inventaire
//   CHARGE — AUCUN rattachement, hors du mécanisme (b) :
//     casse · materiel_endommage · consigne_perdue
//   autre — rattachement optionnel : rattachée → matière, sinon → charge.
//   FOURNITURE (`si_…`) : un écart d'inventaire sur une fourniture est une
//     CHARGE. Il porte l'id de la fourniture dans `ingredient_id` — même
//     convention que `daily_expenses.ingredient_id` — ce qui le rattache
//     (traçable) sans en faire de la matière.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:fortress/core/services/loss_service.dart';
import 'package:fortress/core/services/reconciliation_service.dart';
import 'package:fortress/core/services/restaurant_reporting_service.dart';
import 'package:fortress/core/storage/hive_boxes.dart';
import 'package:fortress/features/dashboard/data/dashboard_providers.dart'
    show DashRange;
import 'package:fortress/features/restaurant/domain/entities/daily_expense.dart';
import 'package:fortress/features/restaurant/domain/entities/ingredient.dart';
import 'package:fortress/features/restaurant/domain/entities/loss.dart';
import 'package:fortress/features/restaurant/domain/entities/stock_item.dart';

const _plates = [WastedPlate(productId: 'p_dg', quantity: 2)];

String? _error(String category,
        {List<WastedPlate> items = const [], String? ingredientId}) =>
    Loss.attachmentError(
        category: category, items: items, ingredientId: ingredientId);

Loss _loss(String category,
        {List<WastedPlate> items = const [], String? ingredientId}) =>
    Loss(
      id: 'ls_x',
      shopId: 'shop',
      description: 'x',
      amount: 1000,
      category: category,
      date: DateTime(2026, 9, 15),
      createdAt: DateTime(2026, 9, 15),
      items: items,
      ingredientId: ingredientId,
    );

final _now = DateTime.now();
final _today = DateTime(_now.year, _now.month, _now.day);
DashRange get _range => DashRange(
    _today.subtract(const Duration(days: 1)),
    _today.add(const Duration(days: 2)));

void main() {
  // ══ Règle pure ══════════════════════════════════════════════════════════
  group('règle de rattachement par catégorie', () {
    for (final cat in ['reste_invendu', 'plat_mal_fait', 'non_paye']) {
      group(cat, () {
        test('sans rattachement → refusée', () {
          expect(_error(cat), isNotNull);
        });
        test('avec des assiettes → acceptée', () {
          expect(_error(cat, items: _plates), isNull);
        });
        test('avec un ingrédient → acceptée', () {
          expect(_error(cat, ingredientId: 'ig_poulet'), isNull);
        });
        test('avec une fourniture seule → refusée (pas de la matière)', () {
          expect(_error(cat, ingredientId: 'si_gaz'), isNotNull);
        });
      });
    }

    group('ecart_inventaire', () {
      test('sans rattachement → refusée', () {
        expect(_error('ecart_inventaire'), isNotNull);
      });
      test('sur un ingrédient → acceptée', () {
        expect(_error('ecart_inventaire', ingredientId: 'ig_poulet'), isNull);
      });
      test('sur une fourniture → acceptée', () {
        expect(_error('ecart_inventaire', ingredientId: 'si_gaz'), isNull);
      });
    });

    for (final cat in ['casse', 'materiel_endommage', 'consigne_perdue']) {
      group(cat, () {
        test('sans rattachement → acceptée', () {
          expect(_error(cat), isNull);
        });
        test('avec des assiettes → refusée (une charge, hors voie b)', () {
          expect(_error(cat, items: _plates), isNotNull);
        });
        test('avec un ingrédient → refusée', () {
          expect(_error(cat, ingredientId: 'ig_poulet'), isNotNull);
        });
      });
    }

    group('autre', () {
      test('sans rattachement → acceptée', () {
        expect(_error('autre'), isNull);
      });
      test('avec des assiettes → acceptée', () {
        expect(_error('autre', items: _plates), isNull);
      });
      test('avec un ingrédient → acceptée', () {
        expect(_error('autre', ingredientId: 'ig_poulet'), isNull);
      });
      test('avec une fourniture → refusée', () {
        expect(_error('autre', ingredientId: 'si_gaz'), isNotNull);
      });
    });
  });

  // ══ Matière ou charge ═══════════════════════════════════════════════════
  group('isMaterial suit la catégorie ET le rattachement', () {
    test('non_paye avec assiettes → matière', () {
      expect(_loss('non_paye', items: _plates).isMaterial, isTrue);
    });
    test('autre rattachée → matière ; non rattachée → charge', () {
      expect(_loss('autre', items: _plates).isMaterial, isTrue);
      expect(_loss('autre').isMaterial, isFalse);
    });
    test('écart d\'inventaire sur fourniture → charge', () {
      expect(_loss('ecart_inventaire', ingredientId: 'si_gaz').isMaterial,
          isFalse);
    });
    test('casse portant des assiettes (donnée hors règle) → reste une charge',
        () {
      expect(_loss('casse', items: _plates).isMaterial, isFalse);
      expect(_loss('consigne_perdue', ingredientId: 'ig_poulet').isMaterial,
          isFalse);
    });
  });

  // ══ Point d'entrée unique — Hive réel ═══════════════════════════════════
  group('LossService refuse la saisie non conforme', () {
    late Directory tmp;

    setUpAll(() async {
      tmp = Directory.systemTemp.createTempSync('fortress_loss_attach');
      Hive.init(tmp.path);
      await Hive.openBox(HiveBoxes.settings);
      for (final b in [
        HiveBoxes.offlineQueue,
        HiveBoxes.products,
        HiveBoxes.orders,
        HiveBoxes.ingredients,
        HiveBoxes.recipeIngredients,
        HiveBoxes.restaurantActivities,
        HiveBoxes.stockItems,
        HiveBoxes.fixedCharges,
        HiveBoxes.losses,
        HiveBoxes.payroll,
        HiveBoxes.dailyExpenses,
      ]) {
        await Hive.openBox<Map>(b);
      }
    });

    tearDownAll(() async {
      await Hive.close();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('record : invendu sans rattachement → exception, rien d\'écrit',
        () async {
      const shop = 'shop_refuse_record';
      await expectLater(
        LossService.record(
            shopId: shop,
            description: 'invendus',
            amount: 3000,
            category: 'reste_invendu'),
        throwsA(isA<LossAttachmentException>()),
      );
      expect(LossService.forShop(shop), isEmpty);
    });

    test('update : retirer le rattachement d\'une perte matière → exception',
        () async {
      const shop = 'shop_refuse_update';
      final l = await LossService.record(
          shopId: shop,
          description: 'plat raté',
          amount: 800,
          category: 'plat_mal_fait',
          items: _plates);
      final stripped = Loss(
        id: l.id,
        shopId: shop,
        description: l.description,
        amount: l.amount,
        category: l.category,
        date: l.date,
        createdAt: l.createdAt,
      );
      await expectLater(
        LossService.update(stripped),
        throwsA(isA<LossAttachmentException>()),
      );
      expect(LossService.byId(shop, l.id)!.items, hasLength(1));
    });

    test('consigne perdue sans rattachement → acceptée', () async {
      const shop = 'shop_accept_deposit';
      final l = await LossService.record(
          shopId: shop,
          description: 'casiers non rendus',
          amount: 2000,
          category: 'consigne_perdue');
      expect(LossService.byId(shop, l.id), isNotNull);
    });

    test('réconciliation : manque sur fourniture → écart rattaché, charge',
        () async {
      const shop = 'shop_reconcile_supply';
      await HiveBoxes.stockItemsBox.put(
          'si_gaz',
          StockItem(
            id: 'si_gaz',
            shopId: shop,
            name: 'Gaz',
            unit: 'bouteille',
            quantity: 5,
            costPerUnit: 1000,
            createdAt: _now,
          ).toMap());

      await ReconciliationService.apply(shopId: shop, variances: const [
        StockVariance(
          item: CountableItem(
              id: 'si_gaz',
              name: 'Gaz',
              unit: 'bouteille',
              theoretical: 5,
              costPerUnit: 1000,
              isIngredient: false),
          actual: 3,
        ),
      ]);

      final losses = LossService.forShop(shop);
      expect(losses, hasLength(1),
          reason: 'la réconciliation des fournitures ne doit pas être bloquée');
      expect(losses.single.ingredientId, 'si_gaz');
      expect(losses.single.isMaterial, isFalse);

      final r = RestaurantReportingService.build(shop, _range);
      expect(r.lossLines.single.value, 2000);
      expect(r.lossLines.single.isRecalculated, isFalse);
    });

    test('réconciliation : manque sur ingrédient → écart rattaché, matière',
        () async {
      const shop = 'shop_reconcile_ingredient';
      await HiveBoxes.ingredientsBox.put(
          'ig_riz',
          Ingredient(
            id: 'ig_riz',
            shopId: shop,
            name: 'Riz',
            unit: 'kg',
            quantity: 10,
            costPerUnit: 100,
            createdAt: _now,
          ).toMap());

      await ReconciliationService.apply(shopId: shop, variances: const [
        StockVariance(
          item: CountableItem(
              id: 'ig_riz',
              name: 'Riz',
              unit: 'kg',
              theoretical: 10,
              costPerUnit: 100,
              isIngredient: true),
          actual: 8,
        ),
      ]);

      final losses = LossService.forShop(shop);
      expect(losses, hasLength(1));
      expect(losses.single.ingredientId, 'ig_riz');
      expect(losses.single.isMaterial, isTrue);
    });

    test('bilan : une casse portant des assiettes reste comptée à son montant',
        () async {
      const shop = 'shop_report_casse_items';
      await HiveBoxes.lossesBox.put('ls_casse_items', {
        'schema_version': 2,
        'id': 'ls_casse_items',
        'shop_id': shop,
        'description': 'casse arrivée par la synchro avec des assiettes',
        'amount': 1500,
        'category': 'casse',
        'origin': '',
        'date': DailyExpense.dayKey(_today),
        'items': [
          {'product_id': 'p_dg', 'quantity': 2}
        ],
        'created_at': _now.toUtc().toIso8601String(),
      });
      final r = RestaurantReportingService.build(shop, _range);
      expect(r.lossLines.single.value, 1500);
      expect(r.lossLines.single.isRecalculated, isFalse);
    });
  });
}
