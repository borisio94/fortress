// BANC DE TEST de la feuille des couverts (plan de salle) — 26/09/2026.
//
// Sortie du plan de salle (lot « classes géantes ») : la page vit sous
// `AppScaffold` et ne se monte pas en test ; la feuille, si. Ce que la page
// fait du nombre (`RestaurantTableService.updateCovers`) n'est pas monté ici.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/theme/app_theme.dart';
import 'package:fortress/features/restaurant/domain/entities/restaurant_table.dart';
import 'package:fortress/features/restaurant/presentation/widgets/table_covers_sheet.dart';
import 'package:fortress/shared/widgets/adaptive_form_frame.dart';

RestaurantTable table({int capacity = 6, int? covers}) => RestaurantTable(
      id: 't1',
      shopId: 'shop1',
      number: 1,
      name: 'Table 1',
      createdAt: DateTime(2026),
      capacity: capacity,
      covers: covers,
      status: covers == null
          ? RestaurantTableStatus.libre
          : RestaurantTableStatus.occupee,
    );

void main() {
  /// Ouvre la feuille comme le plan de salle, et rend un accès au résultat.
  Future<({bool done, int? result}) Function()> open(
    WidgetTester tester,
    RestaurantTable t, {
    String? title,
    String? confirmLabel,
  }) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var done = false;
    int? result;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                result = await showAdaptiveFormSheet<int>(
                  context: ctx,
                  builder: (_) => TableCoversSheet(
                      table: t, title: title, confirmLabel: confirmLabel),
                );
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

  Finder minus() => find.byIcon(Icons.remove_rounded);
  Finder plus() => find.byIcon(Icons.add_rounded);

  /// Le bouton est-il actif ?
  bool enabled(WidgetTester tester, Finder icon) => tester
      .widget<InkWell>(
          find.ancestor(of: icon, matching: find.byType(InkWell)).first)
      .onTap !=
      null;

  Future<void> tap(WidgetTester tester, Finder f) async {
    await tester.tap(f);
    await tester.pumpAndSettle();
  }

  testWidgets('par défaut : « Ouvrir … », capacité en sous-titre, compteur '
      'à la capacité', (tester) async {
    await open(tester, table(capacity: 6));
    expect(find.text('Ouvrir Table 1'), findsOneWidget);
    expect(find.text('Capacité 6 personnes'), findsOneWidget);
    expect(find.text('6'), findsOneWidget);
    expect(find.text('Ouvrir la table'), findsOneWidget);
  });

  testWidgets('ajustement : titre et bouton fournis, compteur aux couverts '
      'actuels', (tester) async {
    await open(tester, table(capacity: 6, covers: 4),
        title: 'Couverts — Table 1', confirmLabel: 'Enregistrer les couverts');
    expect(find.text('Couverts — Table 1'), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
    expect(find.text('Enregistrer les couverts'), findsOneWidget);
  });

  testWidgets('borné à la capacité : « + » inactif à la capacité',
      (tester) async {
    final state = await open(tester, table(capacity: 6, covers: 5));
    expect(enabled(tester, plus()), isTrue);
    await tap(tester, plus());
    expect(find.text('6'), findsOneWidget);
    expect(enabled(tester, plus()), isFalse);
    await tap(tester, plus());
    expect(find.text('6'), findsOneWidget, reason: 'pas au-delà');
    await tap(tester, find.text('Ouvrir la table'));
    expect(state().result, 6);
  });

  testWidgets('jamais sous 1 couvert : « − » inactif à 1', (tester) async {
    final state = await open(tester, table(capacity: 6, covers: 2));
    await tap(tester, minus());
    expect(find.text('1'), findsOneWidget);
    expect(enabled(tester, minus()), isFalse);
    await tap(tester, minus());
    expect(find.text('1'), findsOneWidget);
    await tap(tester, find.text('Ouvrir la table'));
    expect(state().result, 1);
  });

  testWidgets('des convives partent : le nombre ajusté est rendu',
      (tester) async {
    final state = await open(tester, table(capacity: 6, covers: 5),
        confirmLabel: 'Enregistrer les couverts');
    await tap(tester, minus());
    await tap(tester, minus());
    await tap(tester, find.text('Enregistrer les couverts'));
    expect(state().done, isTrue);
    expect(state().result, 3);
  });

  testWidgets('fermée sans valider : aucun résultat', (tester) async {
    final state = await open(tester, table(capacity: 4));
    await tap(tester, minus());
    await tester.state<NavigatorState>(find.byType(Navigator).last).maybePop();
    await tester.pumpAndSettle();
    expect(state().done, isTrue);
    expect(state().result, isNull);
  });
}
