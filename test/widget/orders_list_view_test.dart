// La vue LISTE des commandes du restaurant rendait une page vide en ligne
// (cd67d38, 26/09/2026).
//
// Cause : la ligne de liste mesurait sa largeur avec un `LayoutBuilder`, posé
// sous l'`IntrinsicHeight` qui étire le liseré d'état. Flutter refuse de
// demander ses dimensions intrinsèques à un `LayoutBuilder` : l'assertion
// part à chaque ligne, et en production la ligne ne rend rien.
//
// Aucun test ne montait l'écran — les tests de la carte portaient sur des
// règles pures. Celui-ci monte le VRAI `OrdersTab`, en vue liste, sur Hive
// temporaire, aux deux largeurs (ligne unique et repli sur deux lignes).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:fortress/core/permisions/app_permissions.dart';
import 'package:fortress/core/permisions/subscription_provider.dart';
import 'package:fortress/core/permisions/user_plan.dart';
import 'package:fortress/core/storage/hive_boxes.dart';
import 'package:fortress/core/storage/local_storage_service.dart';
import 'package:fortress/core/theme/app_theme.dart';
import 'package:fortress/features/caisse/presentation/pages/caisse_page.dart';
import 'package:fortress/features/shop_selector/domain/entities/shop_summary.dart';

// Copie de `HiveBoxes._allBoxes` (privée) : l'écran lit des boîtes variées.
const _allBoxes = [
  HiveBoxes.cart,
  HiveBoxes.settings,
  HiveBoxes.offlineQueue,
  HiveBoxes.shops,
  HiveBoxes.users,
  HiveBoxes.memberships,
  HiveBoxes.products,
  HiveBoxes.sales,
  HiveBoxes.clients,
  HiveBoxes.orders,
  HiveBoxes.suppliers,
  HiveBoxes.receptions,
  HiveBoxes.incidents,
  HiveBoxes.stockMovements,
  HiveBoxes.purchaseOrders,
  HiveBoxes.stockArrivals,
  HiveBoxes.activityLogs,
  HiveBoxes.expenses,
  HiveBoxes.notifications,
  HiveBoxes.stockLocations,
  HiveBoxes.stockLevels,
  HiveBoxes.stockTransfers,
  HiveBoxes.deliveryTemplates,
  HiveBoxes.whatsappTemplates,
  HiveBoxes.promoCampaigns,
  HiveBoxes.deliveryTransfers,
  HiveBoxes.deliveryZones,
  HiveBoxes.deliveryQuartiers,
  HiveBoxes.shopTickets,
  HiveBoxes.ticketMessages,
  HiveBoxes.acknowledgedAlerts,
  HiveBoxes.partnerLedger,
  HiveBoxes.pendingImageUploads,
  HiveBoxes.restaurantTables,
  HiveBoxes.dailyMenuAvailability,
  HiveBoxes.ingredients,
  HiveBoxes.recipeIngredients,
  HiveBoxes.restaurantActivities,
  HiveBoxes.stockItems,
  HiveBoxes.fixedCharges,
  HiveBoxes.losses,
  HiveBoxes.payments,
  HiveBoxes.bottleDeposits,
  HiveBoxes.cashClosures,
  HiveBoxes.employees,
  HiveBoxes.timeRecords,
  HiveBoxes.salaryAdvances,
  HiveBoxes.payroll,
  HiveBoxes.dailyExpenses,
  HiveBoxes.staffPenalties,
  HiveBoxes.staffRatings,
  HiveBoxes.staffContests,
  HiveBoxes.staffAbsences,
];
const _untyped = {HiveBoxes.cart, HiveBoxes.settings, HiveBoxes.acknowledgedAlerts};

void main() {
  late Directory tmp;

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('fortress_orders_list');
    Hive.init(tmp.path);
    for (final name in _allBoxes) {
      if (_untyped.contains(name)) {
        await Hive.openBox(name);
      } else {
        await Hive.openBox<Map>(name);
      }
    }
    await LocalStorageService.saveShop(const ShopSummary(
        id: 'shop1',
        name: 'My Resto',
        currency: 'XAF',
        country: 'CM',
        sector: 'restaurant'));
    // La vue LISTE, comme l'opérateur l'a choisie.
    await HiveBoxes.settingsBox.put('orders_view_mode', 'list');
    final now = DateTime.now().toUtc();
    Map<String, dynamic> order(String id, {bool done = false}) => {
          'id': id,
          'shop_id': 'shop1',
          'status': done ? 'completed' : 'scheduled',
          'payment_method': 'cash',
          'created_at': now.toIso8601String(),
          'items': const [],
          'order_type': 'dine_in',
          'sent_to_kitchen': true,
          'kitchen_ready': false,
          'served': false,
          'finished': done,
          'service_state_at': now.toIso8601String(),
        };
    await HiveBoxes.ordersBox.put('c1', order('c1'));
    await HiveBoxes.ordersBox.put('c2', order('c2', done: true));
  });

  tearDownAll(() async {
    await Hive.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<void> pumpAt(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      // Le propriétaire : seul `permissionsProvider` lit Supabase (l'uid).
      overrides: [
        permissionsProvider.overrideWith((ref, shopId) => AppPermissions(
            plan: UserPlan.empty(), isShopOwner: true)),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(body: OrdersTab(shopId: 'shop1')),
      ),
    ));
    await tester.pump();
  }

  for (final (label, width, header) in [
    ('large : une ligne', 1200.0, true),
    ('étroite : deux lignes', 420.0, false),
  ]) {
    testWidgets('vue liste, largeur $label — les lignes se rendent',
        (tester) async {
      final errors = <String>[];
      final previous = FlutterError.onError;
      FlutterError.onError = (d) {
        final frames = d.stack
            .toString()
            .split('\n')
            .where((l) => l.contains('package:fortress'))
            .take(3)
            .join(' | ');
        errors.add('${d.exceptionAsString().split('\n').first} @ $frames');
      };
      await pumpAt(tester, width);
      FlutterError.onError = previous;
      // ignore: avoid_print
      for (final e in errors) print('ERR>> $e');
      expect(errors, isEmpty,
          reason: 'une exception de mise en page = une ligne vide en ligne');
      // Une ligne = un chevron : les deux commandes sont là.
      expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsNWidgets(2));
      // L'en-tête suit la MÊME mesure que les lignes.
      expect(find.text('TEMPS'), header ? findsOneWidget : findsNothing);
    });
  }
}
