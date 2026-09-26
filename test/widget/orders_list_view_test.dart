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
//
// LE LISERÉ D'ÉTAT (26/09/2026) : même grammaire en liste et en grille —
// 4 px (`kStateStripeWidth`), la couleur de l'état pour une commande active,
// `outlineVariant` pour une terminée, qui recule (`stripeColor`).

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
import 'package:fortress/core/theme/app_colors.dart';
import 'package:fortress/core/theme/app_theme.dart';
import 'package:fortress/features/caisse/presentation/pages/caisse_page.dart';
import 'package:fortress/features/restaurant/presentation/widgets/resto_amount_text.dart';
import 'package:fortress/features/restaurant/presentation/widgets/resto_surfaces.dart';
import 'package:fortress/features/restaurant/presentation/widgets/state_stripe.dart';
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
          // Un montant, et son état de paiement : c1 est due, c2 payée.
          'total': 4500.0,
          'payment_status': done ? 'paid' : 'unpaid',
        };
    await HiveBoxes.ordersBox.put('c1', order('c1'));
    await HiveBoxes.ordersBox.put('c2', order('c2', done: true));
  });

  tearDownAll(() async {
    await Hive.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// [mode] : `list` ou `grid`, comme l'opérateur l'a choisi (réglage lu
  /// au montage de l'écran).
  Future<void> pumpAt(WidgetTester tester, double width,
      {String mode = 'list'}) async {
    // Vraie écriture disque : hors du temps simulé du test, sinon elle
    // n'aboutit jamais.
    await tester.runAsync(
        () => HiveBoxes.settingsBox.put('orders_view_mode', mode));
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
      for (final e in errors) {
        // ignore: avoid_print
        print('ERR>> $e');
      }
      expect(errors, isEmpty,
          reason: 'une exception de mise en page = une ligne vide en ligne');
      // Une ligne = un chevron : les deux commandes sont là.
      expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsNWidgets(2));
      // L'en-tête suit la MÊME mesure que les lignes.
      expect(find.text('TEMPS'), header ? findsOneWidget : findsNothing);
    });
  }

  /// Les liserés d'état à l'écran : un `Container` de la largeur du liseré,
  /// peint. Rien d'autre sur cet écran n'a cette forme.
  List<Color> stripes(WidgetTester tester) => tester
      .widgetList<Container>(find.byWidgetPredicate((w) =>
          w is Container &&
          w.color != null &&
          w.constraints?.minWidth == kStateStripeWidth &&
          w.constraints?.maxWidth == kStateStripeWidth))
      .map((c) => c.color!)
      .toList();

  for (final mode in ['list', 'grid']) {
    testWidgets('$mode : un liseré par commande, qui recule quand elle est '
        'terminée', (tester) async {
      await pumpAt(tester, 1200, mode: mode);
      final theme = Theme.of(tester.element(find.byType(OrdersTab)));
      final found = stripes(tester);
      expect(found, hasLength(2),
          reason: 'une commande active + une terminée = deux liserés de '
              '$kStateStripeWidth px');
      // c1 est en préparation : sa couleur d'état.
      expect(found, contains(theme.semantic.warning));
      // c2 est encaissée : elle recule, son liseré aussi.
      expect(found, contains(theme.colorScheme.outlineVariant));
      expect(found, isNot(contains(theme.colorScheme.onSurfaceVariant)),
          reason: 'le gris appuyé faisait de la terminée le trait le plus '
              'marqué de l\'écran');
    });
  }

  // ── Grammaire du panier (26/09/2026) ─────────────────────────────────
  for (final mode in ['list', 'grid']) {
    testWidgets('$mode : montant dû en primaire, payé atténué ; badge au '
        'singulier', (tester) async {
      await pumpAt(tester, 1200, mode: mode);
      final theme = Theme.of(tester.element(find.byType(OrdersTab)));
      final amounts = tester
          .widgetList<RestoAmountText>(find.byType(RestoAmountText))
          .map((w) => w.style.color)
          .toList();
      // Les deux totaux de la sélection, puis les deux commandes.
      expect(amounts, contains(theme.semantic.brandText),
          reason: 'c1 est due : son montant est en primaire');
      expect(amounts, contains(AppColors.textSecondary),
          reason: 'c2 est payée : son montant s\u2019efface');
      expect(find.text('Encaissée'), findsOneWidget,
          reason: 'le badge nomme UNE commande');
      expect(find.text('Encaissées'), findsNothing);
    });
  }

  testWidgets('grille : un filet par carte au-dessus du contenu et du '
      'montant', (tester) async {
    await pumpAt(tester, 1200, mode: 'grid');
    final theme = Theme.of(tester.element(find.byType(OrdersTab)));
    final filets = tester
        .widgetList<Divider>(find.byType(Divider))
        .where((d) =>
            d.height == 1 &&
            d.thickness == 1 &&
            d.color == theme.semantic.borderSubtle)
        .length;
    expect(filets, greaterThanOrEqualTo(2),
        reason: 'une carte active + une terminée = deux filets');
  });

  testWidgets('les totaux de la sélection sont sur un panneau de verre',
      (tester) async {
    await pumpAt(tester, 1200);
    expect(
        find.ancestor(
            of: find.text('Reste à encaisser'),
            matching: find.byType(RestoGlassPanel)),
        findsOneWidget);
  });

  // ── En-tête sur téléphone (26/09/2026) ───────────────────────────────
  testWidgets('au restaurant, jamais de barre « À planifier » — toutes ses '
      'commandes sont `scheduled` sans date', (tester) async {
    for (final width in [390.0, 1200.0]) {
      await pumpAt(tester, width, mode: 'grid');
      expect(find.textContaining('À planifier'), findsNothing,
          reason: 'largeur $width');
    }
  });

  testWidgets('téléphone : pas de totaux ; ordinateur : sur leur panneau',
      (tester) async {
    await pumpAt(tester, 390, mode: 'grid');
    expect(find.text('Reste à encaisser'), findsNothing);
    await pumpAt(tester, 1200, mode: 'grid');
    expect(find.text('Reste à encaisser'), findsOneWidget);
  });

  testWidgets('téléphone : la première commande monte de 123 px (314 → 191)',
      (tester) async {
    await pumpAt(tester, 390, mode: 'grid');
    // MESURÉ avant le lot : chevron de la première carte à 314,5 px ; après,
    // 191,5 — barre « À planifier » (≈ 45) et totaux (≈ 78) retirés. Une
    // carte de grille et son écart font ≈ 123 : une commande de plus.
    final top = tester
        .getRect(find.byIcon(Icons.keyboard_arrow_down_rounded).first)
        .top;
    expect(top, lessThanOrEqualTo(191.5),
        reason: 'barre « À planifier » et totaux retirés du téléphone');
  });

  testWidgets('grille : les titres de section n\u2019apparaissent que s\u2019ils '
      'opposent deux sections', (tester) async {
    await pumpAt(tester, 1200, mode: 'grid');
    expect(find.text('EN COURS'), findsOneWidget);
    expect(find.text('TERMINÉES'), findsOneWidget);
    // Un seul onglet, une seule section : plus de titre.
    await tester.tap(find.textContaining('En préparation').first);
    await tester.pumpAndSettle();
    expect(find.text('EN COURS'), findsNothing);
    expect(find.text('TERMINÉES'), findsNothing);
  });
}

