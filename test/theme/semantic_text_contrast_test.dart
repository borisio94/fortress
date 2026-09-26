import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/theme/app_colors.dart';
import 'package:fortress/core/theme/app_theme.dart';
import 'package:fortress/core/theme/brand_contrast.dart';
import 'package:fortress/core/theme/theme_palette.dart';
import 'package:fortress/features/restaurant/presentation/widgets/resto_tab_kit.dart';

/// Couleurs d'état EN TEXTE (lot du 26/09/2026) — la règle, pas des valeurs.
///
/// Les variantes `*Text` doivent tenir 4,5:1 partout où le restaurant pose
/// du texte : la carte, le fond de page, le verre (blanc 91 % / nuit 86 %
/// composé sur le fond) ET leur propre teinte (10 à 14 %) — sur les huit
/// palettes, dans les deux modes. La mesure a montré que `danger` de BASE
/// échouait sur sa teinte même en sombre (4,34) : c'est ce que ce test tient.
void main() {
  List<(String, ThemeData)> themes() => [
        for (final p in kAllPalettes) ...[
          ('${p.id}/clair', AppTheme.light(palette: p)),
          ('${p.id}/sombre', AppTheme.dark(palette: p)),
        ],
      ];

  List<Color> grounds(ThemeData t) {
    final dark = t.brightness == Brightness.dark;
    final bg = t.scaffoldBackgroundColor;
    final glass = Color.alphaBlend(
        dark
            ? const Color(0xFF0B0F14).withValues(alpha: 0.86)
            : Colors.white.withValues(alpha: 0.91),
        bg);
    return [t.colorScheme.surface, bg, glass];
  }

  group('les variantes *Text tiennent 4,5:1', () {
    for (final (name, t) in themes()) {
      test(name, () {
        final sem = t.semantic;
        for (final (base, text) in [
          (sem.danger, sem.dangerText),
          (sem.warning, sem.warningText),
          (sem.success, sem.successText),
        ]) {
          for (final g in grounds(t)) {
            expect(BrandContrast.contrast(text, g), greaterThanOrEqualTo(4.5));
            // … et sur leur propre teinte, de 10 à 14 %.
            for (final a in [0.10, 0.12, 0.14]) {
              final tint = Color.alphaBlend(base.withValues(alpha: a), g);
              expect(BrandContrast.contrast(text, tint),
                  greaterThanOrEqualTo(4.5));
            }
          }
        }
      });
    }
  });

  test('textFor : la base devient sa variante texte, le reste ne bouge pas',
      () {
    for (final (_, t) in themes()) {
      final sem = t.semantic;
      expect(sem.textFor(sem.danger), sem.dangerText);
      expect(sem.textFor(sem.warning), sem.warningText);
      expect(sem.textFor(sem.success), sem.successText);
      // `info` n'a pas de variante texte : il revient tel quel, et c'est à
      // l'appelant de l'écrire en textSecondary (§ 16).
      expect(sem.textFor(sem.info), sem.info);
      expect(sem.textFor(t.colorScheme.onSurface), t.colorScheme.onSurface);
    }
  });

  testWidgets('restoTextOn : primaire → onSurface, info → textSecondary',
      (tester) async {
    for (final (_, t) in themes()) {
      late Color primary, info, danger;
      // `Theme` direct, pas `MaterialApp(theme:)` : ce dernier ANIME le
      // passage d'un thème à l'autre, et le Builder lirait un thème à
      // mi-chemin entre deux palettes.
      await tester.pumpWidget(Theme(
        data: t,
        child: Builder(builder: (context) {
          primary = restoTextOn(context, t.colorScheme.primary);
          info = restoTextOn(context, t.semantic.info);
          danger = restoTextOn(context, t.semantic.danger);
          return const SizedBox();
        }),
      ));
      expect(primary, t.colorScheme.onSurface);
      expect(info, AppColors.textSecondary);
      expect(danger, t.semantic.dangerText);
    }
  });
}
