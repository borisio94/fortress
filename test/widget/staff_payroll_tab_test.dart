// BANC DE TEST de l'onglet Paie — tests de CARACTÉRISATION (26/09/2026).
//
// Ils figent ce que fait l'onglet AUJOURD'HUI, avant qu'on découpe sa classe
// d'état (lot « classes géantes », ≈ 1 020 lignes). Un test qui casse pendant
// l'extraction signale un comportement perdu — pas un test à « mettre à jour ».
//
// L'onglet est monté seul (`StaffPayrollTab`), sur Hive temporaire, hors
// ligne ; Supabase est initialisé sur une adresse factice pour les services
// qui lisent `Supabase.instance`.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:fortress/core/services/cash_closure_service.dart';
import 'package:fortress/core/services/staff_service.dart';
import 'package:fortress/core/storage/hive_boxes.dart';
import 'package:fortress/core/storage/local_storage_service.dart';
import 'package:fortress/core/theme/app_theme.dart';
import 'package:fortress/core/utils/currency_formatter.dart';
import 'package:fortress/features/restaurant/domain/entities/salary_advance.dart';
import 'package:fortress/features/restaurant/domain/entities/staff_absence.dart';
import 'package:fortress/features/restaurant/domain/entities/staff_member.dart';
import 'package:fortress/features/restaurant/domain/entities/staff_penalty.dart';
import 'package:fortress/features/restaurant/presentation/widgets/staff_payroll_tab.dart';
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
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
        url: 'https://test.invalid', anonKey: 'test-anon-key');
    tmp = Directory.systemTemp.createTempSync('fortress_payroll_tab');
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

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: const Scaffold(body: StaffPayrollTab(shopId: 'shop1')),
    ));
    await tester.pumpAndSettle();
  }

  setUp(() async {
    await HiveBoxes.employeesBox.clear();
    await HiveBoxes.payrollBox.clear();
    await HiveBoxes.salaryAdvancesBox.clear();
    await HiveBoxes.staffPenaltiesBox.clear();
    await HiveBoxes.staffAbsencesBox.clear();
    await HiveBoxes.timeRecordsBox.clear();
    await HiveBoxes.settingsBox.clear();
  });

  const months = [
    'janvier', 'février', 'mars', 'avril', 'mai', 'juin',
    'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre',
  ];
  String monthLabel(DateTime d) => '${months[d.month - 1]} ${d.year}';
  final now = DateTime.now();
  final month = SalaryAdvance.monthKey(now);
  String money(int v) => CurrencyFormatter.format(v.toDouble());

  /// Awa, 100 000 de salaire de base.
  Future<StaffMember> awa(WidgetTester tester) async => (await tester.runAsync(
      () => StaffService.createMember(
          shopId: 'shop1', fullName: 'Awa', baseSalary: 100000)))!;

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
  Finder wallet() => find.byTooltip('Quinzaine, avance, casse');

  /// Laisse partir le message du bas (sa minuterie) avant la fin du test.
  Future<void> dismissSnack(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  }

  testWidgets("sans employé : l'état vide de la paie", (tester) async {
    await mount(tester);
    expect(find.text('Aucun employé'), findsOneWidget);
  });

  testWidgets('mois : le mois courant, puis précédent et suivant',
      (tester) async {
    await mount(tester);
    expect(find.text(monthLabel(now)), findsOneWidget);
    await press(tester, find.byIcon(Icons.chevron_left_rounded));
    expect(find.text(monthLabel(DateTime(now.year, now.month - 1))),
        findsOneWidget);
    await press(tester, find.byIcon(Icons.chevron_right_rounded));
    await press(tester, find.byIcon(Icons.chevron_right_rounded));
    expect(find.text(monthLabel(DateTime(now.year, now.month + 1))),
        findsOneWidget);
  });

  testWidgets('générer : net calculé en direct, fiche écrite, ligne à payer',
      (tester) async {
    final m = await awa(tester);
    await mount(tester);
    expect(find.text('Awa'), findsOneWidget);
    expect(find.text('à générer'), findsOneWidget);

    await press(tester, find.text('Awa'));
    expect(find.text('Paie ${monthLabel(now)}'), findsOneWidget);
    await tester.enterText(field('Primes / heures supplémentaires'), '5000');
    await tester.enterText(field('Retenues (retards, casse…)'), '2000');
    await tester.pumpAndSettle();
    expect(find.text(money(103000)), findsOneWidget,
        reason: 'net = 100 000 + 5 000 − 2 000');
    await press(tester, find.text('Générer la fiche'));

    final slip = StaffService.payslipFor('shop1', m.id, month)!;
    expect(slip.netSalary, 103000);
    expect(slip.bonuses, 5000);
    expect(slip.deductions, 2000);
    expect(find.text('à payer'), findsOneWidget);
    expect(find.text('1 fiche générée'), findsOneWidget);
    await dismissSnack(tester);
  });

  testWidgets('fiche : marquée payée, puis supprimée', (tester) async {
    final m = await awa(tester);
    await tester.runAsync(
        () => StaffService.generatePayslip(member: m, month: month));
    await mount(tester);

    await press(tester, find.text('Awa'));
    expect(find.text('Fiche ${monthLabel(now)}'), findsOneWidget);
    await press(tester, find.text('Marquer comme payée'));
    expect(StaffService.payslipFor('shop1', m.id, month)!.isPaid, isTrue);
    expect(find.text('payée'), findsOneWidget);
    await dismissSnack(tester);

    await press(tester, find.text('Awa'));
    expect(find.textContaining('Payée le'), findsOneWidget);
    await press(tester, find.text('Supprimer la fiche'));
    expect(StaffService.payslipFor('shop1', m.id, month), isNull);
    expect(find.text('à générer'), findsOneWidget);
    await dismissSnack(tester);
  });

  testWidgets('quinzaine : refusée quand la caisse est vide', (tester) async {
    final m = await awa(tester);
    await mount(tester);
    await press(tester, wallet());
    expect(find.textContaining("Jusqu'à ${money(50000)}"), findsOneWidget,
        reason: 'plafond = la moitié du salaire');
    await press(tester, find.text('Verser la quinzaine'));
    expect(find.widgetWithText(TextField, '50000'), findsOneWidget,
        reason: 'le montant est pré-rempli au reste du plafond');
    await press(tester, find.text('Verser'));

    expect(find.textContaining('La caisse ne contient que'), findsOneWidget);
    expect(StaffService.fortnightTaken('shop1', m.id, month), 0);
    await dismissSnack(tester);
  });

  testWidgets('quinzaine : au-delà du plafond refusée, en deçà versée',
      (tester) async {
    final m = await awa(tester);
    await tester.runAsync(
        () => CashClosureService.setOpeningFloat('shop1', 200000));
    await mount(tester);

    await press(tester, wallet());
    await press(tester, find.text('Verser la quinzaine'));
    await tester.enterText(field('Montant versé'), '60000');
    await press(tester, find.text('Verser'));
    expect(find.textContaining("ce n'est plus une quinzaine"), findsOneWidget);
    expect(StaffService.fortnightTaken('shop1', m.id, month), 0);
    await dismissSnack(tester);

    await press(tester, wallet());
    await press(tester, find.text('Verser la quinzaine'));
    await tester.enterText(field('Montant versé'), '30000');
    await press(tester, find.text('Verser'));
    expect(StaffService.fortnightTaken('shop1', m.id, month), 30000);
    expect(find.textContaining('quinzaine'), findsWidgets);
    await dismissSnack(tester);

    await press(tester, wallet());
    expect(find.textContaining("Jusqu'à ${money(20000)}"), findsOneWidget,
        reason: 'le plafond se réduit de ce qui est déjà touché');
  });

  testWidgets('avance : refusée sans motif, enregistrée avec', (tester) async {
    final m = await awa(tester);
    await mount(tester);

    await press(tester, wallet());
    await press(tester, find.text('Avance sur salaire'));
    await tester.enterText(field('Montant'), '10000');
    await press(tester, find.text("Enregistrer l'avance"));
    expect(find.textContaining("Indiquez le motif de l'avance"),
        findsOneWidget);
    expect(StaffService.pendingAdvances('shop1', m.id, month), 0);
    await dismissSnack(tester);

    await press(tester, wallet());
    await press(tester, find.text('Avance sur salaire'));
    await tester.enterText(field('Montant'), '10000');
    await tester.enterText(field('Motif *'), 'Frais de santé');
    await press(tester, find.text("Enregistrer l'avance"));
    expect(StaffService.pendingAdvances('shop1', m.id, month), 10000);
    expect(find.textContaining('avances ${money(10000)}'), findsOneWidget,
        reason: 'la ligne de l’employé annonce la retenue à venir');
    expect(find.textContaining('Frais de santé'), findsOneWidget);
    await dismissSnack(tester);
  });

  testWidgets('avance : supprimée si non retenue, protégée une fois retenue',
      (tester) async {
    final m = await awa(tester);
    await tester.runAsync(() => StaffService.recordAdvance(
        member: m, amount: 8000, reason: 'Transport', month: month));
    await mount(tester);

    await press(tester, find.textContaining('Transport'));
    expect(find.text('Supprimer cette avance ?'), findsOneWidget);
    await press(tester, find.text('Supprimer'));
    expect(StaffService.advances('shop1', month: month), isEmpty);

    await tester.runAsync(() async {
      await StaffService.recordAdvance(
          member: m, amount: 8000, reason: 'Loyer', month: month);
      await StaffService.generatePayslip(member: m, month: month);
    });
    await mount(tester);
    await press(tester, find.textContaining('Loyer'));
    expect(find.textContaining('déjà été retenue'), findsOneWidget);
    expect(StaffService.advances('shop1', month: month), hasLength(1));
    await dismissSnack(tester);
  });

  testWidgets('casse : les deux refus, puis enregistrée et annoncée',
      (tester) async {
    final m = await awa(tester);
    await mount(tester);

    await press(tester, wallet());
    await press(tester, find.text('Imputer une casse'));
    await press(tester, find.text('Enregistrer'));
    expect(find.text('Indiquez le bien et sa valeur.'), findsOneWidget);
    await dismissSnack(tester);

    await press(tester, wallet());
    await press(tester, find.text('Imputer une casse'));
    await tester.enterText(field('Bien détruit *'), 'Blender');
    await tester.enterText(field('Valeur du bien *'), '15000');
    await press(tester, find.text('Enregistrer'));
    expect(find.textContaining('Les circonstances sont obligatoires'),
        findsOneWidget);
    expect(StaffService.penalties('shop1'), isEmpty);
    await dismissSnack(tester);

    await press(tester, wallet());
    await press(tester, find.text('Imputer une casse'));
    await tester.enterText(field('Bien détruit *'), 'Blender');
    await tester.enterText(field('Valeur du bien *'), '15000');
    await tester.enterText(field('Circonstances *'), 'Tombé en le rinçant');
    await press(tester, find.text('Enregistrer'));

    final p = StaffService.penalties('shop1').single;
    expect(p.itemLabel, 'Blender');
    expect(p.amount, 15000);
    expect(p.mode, PenaltyMode.oneShot);
    expect(StaffService.penaltyDueFor('shop1', m.id, month), 15000);
    expect(find.textContaining('retenue à la prochaine paie'), findsOneWidget);
    expect(find.textContaining('${money(15000)} casse'), findsOneWidget,
        reason: 'la ligne annonce la retenue avant la génération');
    await dismissSnack(tester);
  });

  testWidgets('casse remboursée de sa poche : le salaire n’est pas touché',
      (tester) async {
    final m = await awa(tester);
    await mount(tester);
    await press(tester, wallet());
    await press(tester, find.text('Imputer une casse'));
    await tester.enterText(field('Bien détruit *'), 'Verre');
    await tester.enterText(field('Valeur du bien *'), '2000');
    await tester.enterText(field('Circonstances *'), 'Cassé au service');
    await press(tester, find.text('Remboursé de sa poche'));
    expect(find.textContaining('Le salaire ne sera JAMAIS touché'),
        findsOneWidget);
    await press(tester, find.text('Enregistrer'));

    expect(StaffService.penalties('shop1').single.mode, PenaltyMode.cashRepaid);
    expect(StaffService.penaltyDueFor('shop1', m.id, month), 0);
    expect(find.textContaining('salaire non impacté'), findsOneWidget);
    await dismissSnack(tester);
  });

  testWidgets('casse : supprimée après confirmation', (tester) async {
    final m = await awa(tester);
    await tester.runAsync(() => StaffService.recordPenalty(
        member: m, itemLabel: 'Vitre', amount: 5000, reason: 'Choc'));
    await mount(tester);
    await press(tester, find.textContaining('Vitre'));
    expect(find.text('Supprimer cette imputation ?'), findsOneWidget);
    await press(tester, find.text('Supprimer'));
    expect(StaffService.penalties('shop1'), isEmpty);
    expect(find.text('Aucune casse imputée.'), findsOneWidget);
  });

  testWidgets('mise à pied : levée (la ligne reste), puis supprimée',
      (tester) async {
    final m = await awa(tester);
    await tester.runAsync(() => StaffService.recordAbsence(
        member: m,
        kind: AbsenceKind.suspension,
        startDate: DateTime(now.year, now.month, 1),
        endDate: DateTime(now.year, now.month, 2),
        reason: 'Retards répétés'));
    await mount(tester);
    expect(find.textContaining('sans solde'), findsOneWidget);

    await press(tester, find.text('Awa · Mise à pied'));
    await press(tester, find.text('Lever cette décision'));
    expect(StaffService.absences('shop1').single.isCancelled, isTrue);
    expect(find.text('Décision levée.'), findsOneWidget);
    await dismissSnack(tester);
    expect(find.textContaining('levée'), findsOneWidget,
        reason: 'une décision levée reste affichée');

    await press(tester, find.text('Awa · Mise à pied'));
    await press(tester, find.text('Supprimer la ligne'));
    expect(find.text('Supprimer cette ligne ?'), findsOneWidget);
    await press(tester, find.text('Supprimer'));
    expect(StaffService.absences('shop1'), isEmpty);
  });
}
