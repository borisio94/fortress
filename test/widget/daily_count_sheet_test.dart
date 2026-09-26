// BANC DE TEST de la feuille « Stock du jour » (page Menu) — 26/09/2026.
//
// Sortie de la page Menu (lot « classes géantes ») : la page vit sous
// `AppScaffold` et ne se monte pas en test ; la feuille, si. Ce que la page
// fait du résultat (`DailyMenuService.setCount`) n'est pas monté ici.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/theme/app_theme.dart';
import 'package:fortress/features/restaurant/presentation/widgets/daily_count_sheet.dart';
import 'package:fortress/shared/widgets/adaptive_form_frame.dart';

void main() {
  /// Ouvre la feuille comme la page Menu, et rend un accès au résultat.
  Future<({bool done, DailyCountResult? result}) Function()> open(
    WidgetTester tester, {
    int? current,
  }) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var done = false;
    DailyCountResult? result;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                result = await showAdaptiveFormSheet<DailyCountResult>(
                  context: ctx,
                  builder: (_) =>
                      DailyCountSheet(dishName: 'Ndolè', current: current),
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

  Finder field() => find.byType(TextField);

  testWidgets('titre, plat en sous-titre, champ vide pour un stock illimité',
      (tester) async {
    await open(tester);
    expect(find.text('Stock du jour'), findsOneWidget);
    expect(find.text('Ndolè'), findsOneWidget);
    expect(tester.widget<TextField>(field()).controller!.text, isEmpty);
  });

  testWidgets('le stock actuel est pré-rempli', (tester) async {
    await open(tester, current: 12);
    expect(tester.widget<TextField>(field()).controller!.text, '12');
  });

  testWidgets('Enregistrer rend le nombre saisi', (tester) async {
    final state = await open(tester, current: 12);
    await tester.enterText(field(), '20');
    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();
    expect(state().done, isTrue);
    expect(state().result!.count, 20);
  });

  testWidgets('Enregistrer sur un champ vide rend « illimité »',
      (tester) async {
    final state = await open(tester, current: 12);
    await tester.enterText(field(), '');
    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();
    expect(state().result, isNotNull);
    expect(state().result!.count, isNull);
  });

  testWidgets('la touche Entrée vaut Enregistrer', (tester) async {
    final state = await open(tester);
    await tester.enterText(field(), '15');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(state().result!.count, 15);
  });

  testWidgets('« Illimité » ignore ce qui est saisi', (tester) async {
    final state = await open(tester, current: 12);
    await tester.enterText(field(), '5');
    await tester.tap(find.text('Illimité'));
    await tester.pumpAndSettle();
    expect(state().result, isNotNull);
    expect(state().result!.count, isNull);
  });

  testWidgets('le champ n’accepte que des chiffres', (tester) async {
    final state = await open(tester);
    await tester.enterText(field(), '1a2');
    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();
    expect(state().result!.count, 12);
  });

  testWidgets('fermée sans valider : aucun résultat', (tester) async {
    final state = await open(tester, current: 12);
    await tester.state<NavigatorState>(find.byType(Navigator).last).maybePop();
    await tester.pumpAndSettle();
    expect(state().done, isTrue);
    expect(state().result, isNull);
  });
}
