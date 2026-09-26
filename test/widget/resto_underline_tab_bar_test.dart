import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/theme/app_theme.dart';
import 'package:fortress/features/restaurant/presentation/widgets/resto_underline_tabs.dart';

/// Onglets de Finances et Personnel (25/09/2026) : les onglets soulignés
/// remplacent la `TabBar` Material SANS toucher à la navigation — le
/// `TabController` reste la source, un tap l'anime, un balayage met à jour
/// l'onglet actif.
void main() {
  Widget host() => MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: DefaultTabController(
            length: 3,
            child: Column(children: [
              const RestoUnderlineTabBar(labels: ['Un', 'Deux', 'Trois']),
              Expanded(
                child: TabBarView(children: [
                  for (final t in ['page 1', 'page 2', 'page 3'])
                    Center(child: Text(t)),
                ]),
              ),
            ]),
          ),
        ),
      );

  TabController controllerOf(WidgetTester tester) => DefaultTabController.of(
      tester.element(find.byType(RestoUnderlineTabBar)));

  testWidgets('un tap sur un onglet change la page', (tester) async {
    await tester.pumpWidget(host());
    expect(find.text('page 1'), findsOneWidget);
    await tester.tap(find.text('Trois'));
    await tester.pumpAndSettle();
    expect(controllerOf(tester).index, 2);
    expect(find.text('page 3'), findsOneWidget);
  });

  testWidgets('un balayage met à jour l\'onglet actif', (tester) async {
    await tester.pumpWidget(host());
    await tester.fling(find.text('page 1'), const Offset(-600, 0), 1500);
    await tester.pumpAndSettle();
    expect(controllerOf(tester).index, 1);
    // L'onglet actif s'écrit en gras : c'est lui qui suit le contrôleur.
    final deux = tester.widget<Text>(find.descendant(
        of: find.byType(RestoUnderlineTabBar),
        matching: find.byWidgetPredicate((w) =>
            w is Text &&
            (w.textSpan?.toPlainText().startsWith('Deux') ?? false))));
    final span = (deux.textSpan! as TextSpan).children!.first as TextSpan;
    expect(span.style!.fontWeight, FontWeight.w700);
  });

  testWidgets('sans compteur : aucun onglet ne s\'éteint', (tester) async {
    await tester.pumpWidget(host());
    for (final l in ['Un', 'Deux', 'Trois']) {
      expect(find.textContaining(l), findsWidgets);
    }
    // Aucun « 0 » affiché à côté des libellés.
    expect(find.textContaining('  0'), findsNothing);
  });
}
