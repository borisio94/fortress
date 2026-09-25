import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/theme/app_theme.dart';
import 'package:fortress/core/widgets/touch_target.dart';

/// Lot 2 — cibles tactiles (25/09/2026). Au doigt 48 px, à la souris rien ne
/// bouge.
void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  Widget host(Widget child) => MaterialApp(
        home: Scaffold(body: Center(child: child)),
      );

  const dot = SizedBox(key: Key('dot'), width: 28, height: 28);

  group('isTouchPlatform', () {
    test('Android et iOS : tactile', () {
      for (final p in [TargetPlatform.android, TargetPlatform.iOS]) {
        debugDefaultTargetPlatformOverride = p;
        expect(isTouchPlatform, isTrue, reason: p.name);
        expect(compactUnlessTouch, VisualDensity.standard);
        expect(adaptiveTapTargetSize, MaterialTapTargetSize.padded);
      }
    });

    test('Windows, macOS, Linux : souris (iPad sous Safari compris : macOS)',
        () {
      for (final p in [
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.linux,
      ]) {
        debugDefaultTargetPlatformOverride = p;
        expect(isTouchPlatform, isFalse, reason: p.name);
        expect(compactUnlessTouch, VisualDensity.compact);
        expect(adaptiveTapTargetSize, MaterialTapTargetSize.shrinkWrap);
      }
    });
  });

  group('TouchTarget', () {
    testWidgets('au doigt : zone de 48 × 48, dessin inchangé à 28',
        (tester) async {
      await tester.pumpWidget(host(TouchTarget(onTap: () {}, child: dot)));
      expect(tester.getSize(find.byType(TouchTarget)), const Size(48, 48));
      expect(tester.getSize(find.byKey(const Key('dot'))), const Size(28, 28));
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('au doigt : un appui dans la MARGE déclenche le geste',
        (tester) async {
      var taps = 0;
      await tester
          .pumpWidget(host(TouchTarget(onTap: () => taps++, child: dot)));
      final box = tester.getRect(find.byType(TouchTarget));
      // 3 px du coin : hors du rond de 28, dans la zone de 48.
      await tester.tapAt(box.topLeft + const Offset(3, 3));
      expect(taps, 1);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('à la souris : rien ne bouge, 28 × 28', (tester) async {
      await tester.pumpWidget(host(TouchTarget(onTap: () {}, child: dot)));
      expect(tester.getSize(find.byType(TouchTarget)), const Size(28, 28));
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets(
        'parent à hauteur FIXE qui contraint (puce de 38) : plafonné, '
        'sans débordement', (tester) async {
      await tester.pumpWidget(host(SizedBox(
        height: 38,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          TouchTarget(onTap: () {}, child: const Icon(Icons.close, size: 14)),
        ]),
      )));
      expect(tester.takeException(), isNull);
      final size = tester.getSize(find.byType(TouchTarget));
      expect(size.width, 48);
      expect(size.height, 38);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets(
        'parent à hauteur FIXE qui laisse sa colonne libre (tuile de 82) : '
        'DÉBORDE — d\'où la zone superposée du ⋮ de table', (tester) async {
      // La tuile de table : 82 px, ~70 de contenu, dont une rangée de 22 px
      // pour le nom et le ⋮. La rangée montée à 48 fait déborder.
      await tester.pumpWidget(host(SizedBox(
        height: 82,
        width: 160,
        child: Column(children: [
          Row(children: [
            const Expanded(child: Text('Table 4')),
            TouchTarget(onTap: () {}, child: const Icon(Icons.more_vert)),
          ]),
          const SizedBox(height: 16),
          const SizedBox(height: 16),
          const SizedBox(height: 16),
        ]),
      )));
      expect(tester.takeException(), isFlutterError,
          reason: 'le piège documenté dans touch_target.dart');
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  });

  group('Thème : tapTargetSize des boutons', () {
    ButtonStyle? elevated(ThemeData t) => t.elevatedButtonTheme.style;

    test('au doigt : padded (clair et sombre, quatre boutons)', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      for (final t in [AppTheme.light(), AppTheme.dark()]) {
        for (final s in [
          elevated(t),
          t.outlinedButtonTheme.style,
          t.textButtonTheme.style,
          t.filledButtonTheme.style,
        ]) {
          expect(s!.tapTargetSize, MaterialTapTargetSize.padded);
        }
      }
    });

    test('à la souris : shrinkWrap, densité de bureau inchangée', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      for (final t in [AppTheme.light(), AppTheme.dark()]) {
        expect(elevated(t)!.tapTargetSize, MaterialTapTargetSize.shrinkWrap);
        expect(t.filledButtonTheme.style!.tapTargetSize,
            MaterialTapTargetSize.shrinkWrap);
      }
    });

    testWidgets('au doigt, un bouton du thème occupe 48 px de haut',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Center(
            child: TextButton(onPressed: () {}, child: const Text('OK')),
          ),
        ),
      ));
      expect(tester.getSize(find.byType(TextButton)).height,
          greaterThanOrEqualTo(48));
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  });
}
