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
import 'package:fortress/core/services/staff_service.dart';
import 'package:fortress/core/storage/hive_boxes.dart';
import 'package:fortress/core/storage/local_storage_service.dart';
import 'package:fortress/core/theme/app_theme.dart';
import 'package:fortress/features/hr/data/providers/employees_provider.dart';
import 'package:fortress/features/hr/domain/models/employee.dart';
import 'package:fortress/features/hr/domain/models/employee_permission.dart';
import 'package:fortress/features/hr/domain/models/member_role.dart';
import 'package:fortress/features/restaurant/domain/entities/staff_absence.dart';
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

  setUp(() async {
    await HiveBoxes.employeesBox.clear();
    await HiveBoxes.staffAbsencesBox.clear();
    await HiveBoxes.settingsBox.clear();
  });

  List<StaffMember> staff() => StaffService.forShop('shop1');

  /// Appuie (en faisant défiler) et laisse les écritures Hive aboutir hors du
  /// temps simulé.
  Future<void> press(WidgetTester tester, Finder f) async {
    await tester.ensureVisible(f);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(f);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
  }

  Finder field(String label) => find.widgetWithText(TextField, label);

  /// Laisse partir le message du bas (sa minuterie) avant la fin du test.
  Future<void> dismissSnack(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  }

  /// Un membre du personnel SANS compte, écrit directement en base.
  Future<StaffMember> seed(
    WidgetTester tester,
    String name, {
    String? phone,
    String? closingTime,
    String? pin,
    bool active = true,
  }) async =>
      (await tester.runAsync(() async {
        var m = await StaffService.createMember(
            shopId: 'shop1',
            fullName: name,
            baseSalary: 60000,
            phone: phone,
            closingTime: closingTime,
            hasAppAccess: false);
        if (pin != null) m = (await StaffService.setPin(m, pin))!;
        if (!active) {
          m = await StaffService.saveMember(m.copyWith(isActive: false));
        }
        return m;
      }))!;

  Employee account(String userId, String name, String jobTitle) => Employee(
        userId: userId,
        shopId: 'shop1',
        fullName: name,
        email: '$userId@test.invalid',
        role: MemberRole.user,
        jobTitle: jobTitle,
        status: EmployeeStatus.active,
        permissions: const {},
      );

  /// Passe la création en « Non, personnel seul ».
  Future<void> noAccount(WidgetTester tester) =>
      press(tester, find.text('Non, personnel seul'));

  testWidgets('création : la question du compte ouvre la fiche',
      (tester) async {
    await open(tester);
    expect(find.text('Nouvel employé'), findsOneWidget);
    expect(find.text("Cette personne utilise-t-elle l'application ?"),
        findsOneWidget);
  });

  testWidgets('avec compte, sans choix : refus qui dit de choisir la personne',
      (tester) async {
    await open(tester, accounts: [account('u1', 'Awa Ndiaye', 'Serveuse')]);
    await press(tester, find.text('Créer'));
    expect(find.text('Choisissez la personne parmi les comptes de la boutique.'),
        findsOneWidget);
    expect(staff(), isEmpty);
  });

  testWidgets('avec compte : la personne choisie apporte nom, fonction et lien',
      (tester) async {
    final state =
        await open(tester, accounts: [account('u1', 'Awa Ndiaye', 'Serveuse')]);
    await press(tester, find.byIcon(Icons.person_outline_rounded));
    await press(tester, find.text('Awa Ndiaye').last);
    expect(find.text('Serveuse'), findsOneWidget,
        reason: 'la fonction vient du compte, en lecture seule');
    await tester.enterText(field('Salaire de base'), '80000');
    await press(tester, find.text('Créer'));

    expect(state().result, isTrue);
    final m = staff().single;
    expect(m.fullName, 'Awa Ndiaye');
    expect(m.role, 'Serveuse');
    expect(m.userId, 'u1');
    expect(m.hasAppAccess, isTrue);
    expect(m.baseSalary, 80000);
  });

  testWidgets('avec compte : un compte déjà inscrit ne se propose plus',
      (tester) async {
    await tester.runAsync(() => StaffService.createMember(
        shopId: 'shop1', fullName: 'Awa Ndiaye', userId: 'u1'));
    await open(tester, accounts: [account('u1', 'Awa Ndiaye', 'Serveuse')]);
    expect(find.text('Aucun compte disponible'), findsOneWidget);
    expect(
        find.textContaining('Tous les comptes de la boutique sont déjà inscrits'),
        findsOneWidget);
  });

  testWidgets('aucun compte : la fiche dit où les créer', (tester) async {
    await open(tester);
    expect(find.text('Aucun compte disponible'), findsOneWidget);
    expect(find.textContaining("Créez d'abord le compte"), findsOneWidget);
  });

  testWidgets('sans compte : créée avec nom, salaire, poste, téléphone, code',
      (tester) async {
    final state = await open(tester);
    await noAccount(tester);
    await tester.enterText(field('Nom complet *'), 'Paul Mbarga');
    await tester.enterText(field('Salaire de base'), '50000');
    await tester.enterText(field('Poste'), 'Plonge');
    await tester.enterText(field('Téléphone'), '699000111');
    await tester.enterText(field('Code'), '4321');
    await press(tester, find.text('Créer'));

    expect(state().result, isTrue);
    final m = staff().single;
    expect(m.fullName, 'Paul Mbarga');
    expect(m.hasAppAccess, isFalse);
    expect(m.userId, isNull);
    expect(m.baseSalary, 50000);
    expect(m.station, 'Plonge');
    expect(m.phone, '699000111');
    expect(m.hasPin, isTrue);
  });

  testWidgets('changer de mode vide le nom saisi', (tester) async {
    await open(tester);
    await noAccount(tester);
    await tester.enterText(field('Nom complet *'), 'Paul');
    await press(tester, find.text('Oui, elle a un compte'));
    await noAccount(tester);
    expect(find.widgetWithText(TextField, 'Paul'), findsNothing);
  });

  testWidgets('sans compte : nom vide, puis nom déjà au personnel',
      (tester) async {
    await seed(tester, 'Awa');
    await open(tester);
    await noAccount(tester);
    await press(tester, find.text('Créer'));
    expect(find.text('Nom requis'), findsOneWidget);

    await tester.enterText(field('Nom complet *'), 'awa');
    await press(tester, find.text('Créer'));
    expect(find.text('awa figure déjà dans le personnel.'), findsOneWidget);
    expect(staff(), hasLength(1));
  });

  testWidgets('téléphone déjà pris, même par une fiche archivée',
      (tester) async {
    await seed(tester, 'Awa', phone: '699123456', active: false);
    await open(tester);
    await noAccount(tester);
    await tester.enterText(field('Nom complet *'), 'Binta');
    await tester.enterText(field('Téléphone'), '699123456');
    await press(tester, find.text('Créer'));
    expect(
        find.text('Ce numéro est déjà celui de Awa (fiche archivée).'),
        findsOneWidget);
    expect(staff(), hasLength(1));
  });

  testWidgets('code de pointage : 4 chiffres, et pas celui d’un autre',
      (tester) async {
    await seed(tester, 'Awa', pin: '1234');
    await open(tester);
    await noAccount(tester);
    await tester.enterText(field('Nom complet *'), 'Binta');
    await tester.enterText(field('Code'), '12');
    await press(tester, find.text('Créer'));
    expect(find.text('Le code de pointage fait 4 chiffres'), findsOneWidget);

    await tester.enterText(field('Code'), '1234');
    await press(tester, find.text('Créer'));
    expect(
        find.text('Ce code est déjà celui de Awa. Choisissez-en un autre.'),
        findsOneWidget);
    expect(staff(), hasLength(1));
  });

  testWidgets('modification : même fiche, salaire mis à jour, nom modifiable '
      'sans compte', (tester) async {
    final awa = await seed(tester, 'Awa');
    final state = await open(tester, existing: awa);
    expect(find.text("Cette personne utilise-t-elle l'application ?"),
        findsNothing);
    await tester.enterText(find.widgetWithText(TextField, '60000'), '65000');
    await tester.enterText(find.widgetWithText(TextField, 'Awa'), 'Awa N.');
    await press(tester, find.text('Enregistrer'));

    expect(state().result, isTrue);
    final m = staff().single;
    expect(m.id, awa.id);
    expect(m.fullName, 'Awa N.');
    expect(m.baseSalary, 65000);
  });

  testWidgets('modification avec compte : le nom est en lecture seule',
      (tester) async {
    final m = (await tester.runAsync(() => StaffService.createMember(
        shopId: 'shop1', fullName: 'Awa Ndiaye', userId: 'u1')))!;
    await open(tester,
        existing: m, accounts: [account('u1', 'Awa Ndiaye', 'Serveuse')]);
    expect(find.widgetWithText(TextField, 'Awa Ndiaye'), findsNothing);
    expect(find.text('Awa Ndiaye'), findsWidgets);
  });

  testWidgets("horaire particulier retiré : la fiche suit l'établissement",
      (tester) async {
    final awa = await seed(tester, 'Awa', closingTime: '11:00');
    await open(tester, existing: awa);
    expect(find.text('11:00'), findsOneWidget);
    await press(tester, find.text('Retirer'));
    expect(find.text('Comme la boutique'), findsOneWidget);
    await press(tester, find.text('Enregistrer'));
    expect(staff().single.closingTime, isNull);
  });

  testWidgets('code retiré depuis la fiche', (tester) async {
    final awa = await seed(tester, 'Awa', pin: '1234');
    final state = await open(tester, existing: awa);
    expect(find.text('Nouveau code'), findsOneWidget);
    await press(tester, find.text('Retirer'));
    expect(state().result, isTrue);
    expect(staff().single.hasPin, isFalse);
  });

  testWidgets('mise à pied : motif exigé, puis enregistrée sans solde',
      (tester) async {
    final awa = await seed(tester, 'Awa');
    final state = await open(tester, existing: awa);
    await press(tester, find.text('Mise à pied'));
    await press(tester, find.text('Enregistrer').last);
    expect(find.textContaining('Le motif est obligatoire'), findsOneWidget);
    expect(StaffService.absences('shop1'), isEmpty);
    expect(state().done, isFalse, reason: 'la fiche reste ouverte');
    await dismissSnack(tester);

    // Le motif oublié ferme la feuille de la décision : on la rouvre.
    await press(tester, find.text('Mise à pied'));
    await tester.enterText(field('Motif *'), 'Retards répétés');
    await press(tester, find.text('Enregistrer').last);

    expect(state().result, isTrue, reason: 'la fiche se referme');
    final a = StaffService.absences('shop1').single;
    expect(a.kind, AbsenceKind.suspension);
    expect(a.isPaid, isFalse);
    expect(a.reason, 'Retards répétés');
    expect(find.text('Mise à pied enregistrée.'), findsOneWidget);
    await dismissSnack(tester);
  });

  testWidgets('mise à pied conservatoire : salaire maintenu', (tester) async {
    final awa = await seed(tester, 'Awa');
    await open(tester, existing: awa);
    await press(tester, find.text('Mise à pied'));
    await tester.enterText(field('Motif *'), 'Vérification des faits');
    await press(tester, find.text('Maintenir le salaire'));
    expect(find.textContaining('Mise à pied conservatoire'), findsOneWidget);
    await press(tester, find.text('Enregistrer').last);
    expect(StaffService.absences('shop1').single.isPaid, isTrue);
    await dismissSnack(tester);
  });

  testWidgets('congé payé : payé par définition', (tester) async {
    final awa = await seed(tester, 'Awa');
    await open(tester, existing: awa);
    await press(tester, find.text('Congé payé'));
    expect(find.text('Maintenir le salaire'), findsNothing);
    await tester.enterText(field('Motif *'), 'Congé annuel');
    await press(tester, find.text('Enregistrer').last);
    final a = StaffService.absences('shop1').single;
    expect(a.kind, AbsenceKind.paidLeave);
    expect(a.isPaid, isTrue);
    await dismissSnack(tester);
  });

  testWidgets('absence en cours : affichée, puis levée', (tester) async {
    final awa = await seed(tester, 'Awa');
    final today = DateTime.now();
    await tester.runAsync(() => StaffService.recordAbsence(
        member: awa,
        kind: AbsenceKind.suspension,
        startDate: today,
        endDate: today.add(const Duration(days: 2)),
        reason: 'Retards répétés'));
    final state = await open(tester, existing: awa);
    expect(find.textContaining('« Retards répétés »'), findsOneWidget);
    await press(tester, find.text('Lever'));
    expect(find.text('Lever cette mise à pied ?'), findsOneWidget);
    await press(tester, find.text('Lever').last);

    expect(state().result, isTrue);
    expect(StaffService.absences('shop1').single.isCancelled, isTrue);
  });

  testWidgets('archiver puis réactiver', (tester) async {
    final awa = await seed(tester, 'Awa');
    var state = await open(tester, existing: awa);
    await press(tester, find.text('Archiver'));
    expect(find.text('Archiver Awa ?'), findsOneWidget);
    await press(tester, find.text('Archiver').last);
    expect(state().result, isTrue);
    expect(staff().single.isActive, isFalse);

    state = await open(tester, existing: staff().single);
    await press(tester, find.text('Réactiver'));
    await press(tester, find.text('Réactiver').last);
    expect(staff().single.isActive, isTrue);
  });

  testWidgets('supprimer : motif exigé, puis fiche supprimée', (tester) async {
    final awa = await seed(tester, 'Awa');
    final state = await open(tester, existing: awa);
    await press(tester, find.text('Supprimer'));
    expect(find.text('Supprimer Awa ?'), findsOneWidget);
    await press(tester, find.text('Supprimer définitivement'));
    expect(find.textContaining('Le motif est obligatoire'), findsOneWidget);
    expect(staff(), hasLength(1));
    expect(state().done, isFalse, reason: 'la fiche reste ouverte');
    await dismissSnack(tester);

    await press(tester, find.text('Supprimer'));
    await tester.enterText(
        field('Motif de la suppression *'), 'Fiche créée par erreur');
    await press(tester, find.text('Supprimer définitivement'));
    expect(state().result, isTrue);
    expect(staff(), isEmpty);
    expect(find.textContaining('supprimé — historique conservé'),
        findsOneWidget);
    await dismissSnack(tester);
  });
}
