// BANC DE TEST de la fiche plat — tests de CARACTÉRISATION (26/09/2026).
//
// Ils figent ce que fait la fiche AUJOURD'HUI, avant qu'on en extraie les
// morceaux (lot « classes géantes » : son état fait ≈ 1 260 lignes). Un test
// qui casse pendant l'extraction signale un comportement perdu — pas un test
// à « mettre à jour ».
//
// La fiche est ouverte par son VRAI point d'entrée (`showDishForm`), sur Hive
// temporaire, hors ligne : `AppDatabase` écrit dans Hive et met en file, comme
// sur un appareil sans réseau. Supabase est initialisé sur une adresse
// factice : le journal d'activité (`ActivityLogService.log`, appelé par
// `saveCategory`) lit `Supabase.instance`, et lèverait sinon.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:fortress/core/services/activity_service.dart';
import 'package:fortress/core/services/ingredient_service.dart';
import 'package:fortress/core/services/recipe_service.dart';
import 'package:fortress/core/storage/hive_boxes.dart';
import 'package:fortress/core/storage/local_storage_service.dart';
import 'package:fortress/core/theme/app_theme.dart';
import 'package:fortress/features/inventaire/domain/entities/product.dart';
import 'package:fortress/features/restaurant/presentation/widgets/dish_form_sheet.dart';
import 'package:fortress/features/shop_selector/domain/entities/shop_summary.dart';
import 'package:fortress/shared/widgets/app_primary_button.dart';

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
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
        url: 'https://test.invalid', anonKey: 'test-anon-key');
    tmp = Directory.systemTemp.createTempSync('fortress_dish_form');
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
    await HiveBoxes.settingsBox.put('categories_shop1', ['Plats', 'Boissons']);
  });

  tearDownAll(() async {
    await Hive.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  List<Product> dishes() => LocalStorageService.getProductsForShop('shop1');

  /// Ouvre la fiche par `showDishForm` et rend un accès au résultat.
  Future<({bool done, bool? result}) Function()> open(
    WidgetTester tester, {
    Product? existing,
    bool requireIngredient = false,
  }) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var done = false;
    bool? result;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                result = await showDishForm(
                    context: ctx,
                    shopId: 'shop1',
                    existing: existing,
                    requireIngredient: requireIngredient);
                done = true;
              },
              child: const Text('ouvrir'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('ouvrir'));
    await tester.pumpAndSettle();
    return () => (done: done, result: result);
  }

  /// Le champ qui porte ce texte d'aide (tant qu'il est vide).
  Finder field(String hint) => find.widgetWithText(TextField, hint);

  /// Appuie sur un bouton (en le faisant défiler à l'écran) et laisse les
  /// écritures Hive — de vraies entrées/sorties — aboutir hors du temps simulé.
  Future<void> press(WidgetTester tester, Finder f) async {
    await tester.ensureVisible(f);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(f);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
  }

  setUp(() async {
    await HiveBoxes.productsBox.clear();
    await HiveBoxes.recipeIngredientsBox.clear();
    await HiveBoxes.ingredientsBox.clear();
    await HiveBoxes.restaurantActivitiesBox.clear();
  });

  /// Remplit nom, catégorie « Plats » et prix : le minimum d'un plat valide.
  Future<void> fillMinimum(WidgetTester tester, String name) async {
    await tester.enterText(field('Poulet DG'), name);
    await press(tester, find.text('Plats'));
    await tester.enterText(field('3500'), '4000');
  }

  testWidgets('création : les refus arrivent dans l\'ordre nom → catégorie → prix',
      (tester) async {
    final state = await open(tester);
    expect(find.text('Créer le plat'), findsOneWidget);

    await press(tester, find.text('Créer le plat'));
    expect(find.text('Donnez un nom au plat.'), findsOneWidget);

    await tester.enterText(field('Poulet DG'), 'Ndolè');
    await press(tester, find.text('Créer le plat'));
    expect(find.text('Choisissez une catégorie.'), findsOneWidget);

    await press(tester, find.text('Plats'));
    await press(tester, find.text('Créer le plat'));
    expect(find.text('Indiquez un prix valide.'), findsOneWidget);

    expect(state().done, isFalse, reason: 'la fiche reste ouverte');
    expect(dishes(), isEmpty, reason: 'rien n\'est enregistré');
  });

  testWidgets('création valide : la fiche se ferme sur true, le plat est écrit',
      (tester) async {
    final state = await open(tester);
    await tester.enterText(field('Poulet DG'), 'Ndolè');
    await press(tester, find.text('Plats'));
    await tester.enterText(field('3500'), '4500');
    await press(tester, find.text('Créer le plat'));

    expect(state().done, isTrue);
    expect(state().result, isTrue);
    final saved = dishes();
    expect(saved, hasLength(1));
    expect(saved.single.name, 'Ndolè');
    expect(saved.single.priceSellPos, 4500);
    expect(saved.single.categoryId, 'Plats');
  });

  testWidgets('ingrédient exigé : bouton désactivé et consigne affichée tant '
      'que la composition est vide', (tester) async {
    final state = await open(tester, requireIngredient: true);
    await tester.enterText(field('Poulet DG'), 'Eru');
    await press(tester, find.text('Plats'));
    await tester.enterText(field('3500'), '3000');

    final button = tester.widget<AppPrimaryButton>(
        find.widgetWithText(AppPrimaryButton, 'Créer le plat'));
    expect(button.enabled, isFalse,
        reason: 'on ne crée pas un plat sans composition dans ce parcours');
    expect(
        find.textContaining('Ajoutez au moins 1 ingrédient pour continuer'),
        findsOneWidget);

    await press(tester, find.text('Créer le plat'));
    expect(state().done, isFalse);
    expect(dishes(), isEmpty);
  });

  testWidgets('édition : champs pré-remplis, même identifiant à l\'enregistrement',
      (tester) async {
    // Un plat créé par la fiche elle-même.
    var state = await open(tester);
    await tester.enterText(field('Poulet DG'), 'Koki');
    await press(tester, find.text('Boissons'));
    await tester.enterText(field('3500'), '2000');
    await press(tester, find.text('Créer le plat'));
    final created = dishes().single;

    expect(find.text('Supprimer'), findsNothing,
        reason: 'pas de suppression pour un plat qui n\'existe pas encore');

    state = await open(tester, existing: created);
    expect(find.text('Enregistrer'), findsOneWidget);
    expect(find.text('Supprimer'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Koki'), findsOneWidget);
    expect(find.widgetWithText(TextField, '2000'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, '2000'), '2500');
    await press(tester, find.text('Enregistrer'));

    expect(state().result, isTrue);
    final after = dishes();
    expect(after, hasLength(1), reason: 'modifié, pas dupliqué');
    expect(after.single.id, created.id);
    expect(after.single.priceSellPos, 2500);
  });

  testWidgets('nom en double : l\'avertissement apparaît', (tester) async {
    var state = await open(tester);
    await tester.enterText(field('Poulet DG'), 'Poisson braisé');
    await press(tester, find.text('Plats'));
    await tester.enterText(field('3500'), '5000');
    await press(tester, find.text('Créer le plat'));
    expect(state().result, isTrue);

    state = await open(tester);
    await tester.enterText(field('Poulet DG'), 'poisson braisé');
    await tester.pumpAndSettle();
    expect(find.textContaining('existe déjà à la carte'), findsOneWidget);
  });

  testWidgets('nouvelle catégorie : saisie, ajoutée et choisie', (tester) async {
    await open(tester);
    await press(tester, find.text('+ Nouvelle'));
    expect(find.text('Nouvelle catégorie'), findsOneWidget);
    await tester.enterText(field('Entrées, Plats, Boissons…'), 'Desserts');
    await press(tester, find.text('Ajouter'));
    // L'écriture Hive de `saveCategory` part APRÈS la fermeture de la feuille
    // (hors de la fenêtre de `press`) : on la laisse aboutir en temps réel.
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    expect(find.text('Nouvelle catégorie'), findsNothing,
        reason: 'la feuille de saisie s\'est refermée');
    expect(LocalStorageService.getCategories('shop1'), contains('Desserts'));
    expect(find.text('Desserts'), findsOneWidget,
        reason: 'la nouvelle catégorie est proposée dans la fiche');
  });

  testWidgets('composition : un ingrédient coché est écrit dans la recette',
      (tester) async {
    final ing = (await tester.runAsync(() =>
        IngredientService.create(shopId: 'shop1', name: 'Tomate')))!;
    final state = await open(tester);
    await fillMinimum(tester, 'Omelette');
    expect(find.text('Générosité des portions'), findsNothing);

    await press(tester, find.text('Tomate'));
    expect(find.text('Générosité des portions'), findsOneWidget,
        reason: 'le bloc des portions apparaît avec le premier ingrédient');
    await press(tester, find.text('Créer le plat'));

    expect(state().result, isTrue);
    final lines = RecipeService.forProduct('shop1', dishes().single.id!);
    expect(lines.map((l) => l.ingredientId), [ing.id]);
  });

  testWidgets('composition : « Vider la composition » retire tout après '
      'confirmation', (tester) async {
    await tester.runAsync(
        () => IngredientService.create(shopId: 'shop1', name: 'Oignon'));
    await open(tester);
    await press(tester, find.text('Oignon'));
    await press(tester, find.text('Vider la composition'));
    expect(find.text('Supprimer la fiche recette ?'), findsOneWidget);
    await press(tester, find.text('Supprimer'));

    expect(find.text('Générosité des portions'), findsNothing);
    expect(find.text('Vider la composition'), findsNothing);
  });

  testWidgets('réglages repliés : coût, stock, vitrine et secteur sont '
      'enregistrés', (tester) async {
    final bar = (await tester.runAsync(
        () => ActivityService.create(shopId: 'shop1', name: 'Bar')))!;
    final state = await open(tester);
    await fillMinimum(tester, 'Bière');

    expect(find.text('Secteur à choisir'), findsOneWidget,
        reason: 'repli fermé, boutique à secteurs, aucun choisi');
    expect(find.text('Suivre le stock'), findsNothing);
    await press(tester, find.text('Coût, secteur, stock et visibilité'));
    expect(find.text('Secteur à choisir'), findsNothing);

    await tester.enterText(field('0'), '1200');
    // Ordre des interrupteurs : stock, vente, vitrine.
    await press(tester, find.byType(Switch).at(0));
    await press(tester, find.byType(Switch).at(2));
    await press(tester, find.text('Bar'));
    await press(tester, find.text('Créer le plat'));

    expect(state().result, isTrue);
    final p = dishes().single;
    expect(p.priceBuy, 1200);
    expect(p.trackStock, isTrue);
    expect(p.isActive, isTrue);
    expect(p.isVisibleWeb, isFalse);
    expect(p.activityId, bar.id);
  });
}
