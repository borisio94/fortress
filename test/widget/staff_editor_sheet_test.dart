// BANC DE TEST de la fiche employé — tests de CARACTÉRISATION (26/09/2026).
//
// Ils figent ce que fait la fiche AUJOURD'HUI, avant qu'on découpe sa classe
// d'état (lot « classes géantes », ≈ 745 lignes). Un test qui casse pendant
// l'extraction signale un comportement perdu — pas un test à « mettre à jour ».
//
// La fiche est ouverte seule (`StaffEditorSheet`) dans une feuille, sur Hive
// temporaire, hors ligne. Les comptes « Accès à l'app » viennent d'un
// `employeesProvider` remplacé : le vrai interroge Supabase.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:fortress/core/storage/hive_boxes.dart';
import 'package:fortress/core/storage/local_storage_service.dart';
import 'package:fortress/core/theme/app_theme.dart';
import 'package:fortress/features/hr/data/providers/employees_provider.dart';
import 'package:fortress/features/hr/domain/models/employee.dart';
import 'package:fortress/features/restaurant/domain/entities/staff_member.dart';
import 'package:fortress/features/restaurant/presentation/widgets/staff_editor_sheet.dart';
import 'package:fortress/features/shop_selector/domain/entities/shop_summary.dart';
import 'package:fortress/shared/widgets/adaptive_form_frame.dart';

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

/// Les comptes « Accès à l'app » de la boutique, sans réseau.
class _FakeEmployees extends EmployeesNotifier {
  final List<Employee> accounts;
  _FakeEmployees(this.accounts);

  @override
  Future<List<Employee>> build(String shopId) async => accounts;
}

void main() {
  late Directory tmp;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
        url: 'https://test.invalid', anonKey: 'test-anon-key');
    tmp = Directory.systemTemp.createTempSync('fortress_staff_editor');
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
  });

  tearDownAll(() async {
    await Hive.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// Ouvre la fiche par une feuille, comme l'onglet Équipe, et rend un accès
  /// au résultat.
  Future<({bool done, bool? result}) Function()> open(
    WidgetTester tester, {
    StaffMember? existing,
    List<Employee> accounts = const [],
  }) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var done = false;
    bool? result;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        employeesProvider.overrideWith(() => _FakeEmployees(accounts)),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await showAdaptiveFormSheet<bool>(
                    context: ctx,
                    builder: (_) =>
                        StaffEditorSheet(shopId: 'shop1', existing: existing),
                  );
                  done = true;
                },
                child: const Text('ouvrir'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('ouvrir'));
    await tester.pumpAndSettle();
    return () => (done: done, result: result);
  }

  testWidgets('création : la question du compte ouvre la fiche',
      (tester) async {
    await open(tester);
    expect(find.text('Nouvel employé'), findsOneWidget);
    expect(find.text("Cette personne utilise-t-elle l'application ?"),
        findsOneWidget);
  });
}
