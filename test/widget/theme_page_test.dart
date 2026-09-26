import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/theme/app_theme.dart';
import 'package:fortress/core/theme/brand_contrast.dart';
import 'package:fortress/core/theme/theme_palette.dart';
import 'package:fortress/features/parametres/presentation/pages/theme_page.dart';

/// Page Apparence (25/09/2026) — les pavés montrent ce que la palette
/// PRODUIT, lu dans le thème réel ; le sous-titre dit l'état réel.
void main() {
  group('themeSwatches — lus dans le thème réel, pas dans une table', () {
    for (final b in Brightness.values) {
      for (final p in kAllPalettes) {
        test('${p.id} · ${b.name}', () {
          final sw = themeSwatches(p, b);
          final t = b == Brightness.dark
              ? AppTheme.dark(palette: p)
              : AppTheme.light(palette: p);
          expect(sw.text, t.colorScheme.primary);
          expect(sw.fill,
              t.elevatedButtonTheme.style!.backgroundColor!.resolve({}));
          expect(sw.surface, t.semantic.brandSurface);
        });
      }
    }

    test('en sombre : la variante texte du lot 1, et un fond qui porte le blanc',
        () {
      for (final p in kAllPalettes) {
        final sw = themeSwatches(p, Brightness.dark);
        expect(sw.text, BrandContrast.darkText(p.primary), reason: p.id);
        expect(
            BrandContrast.contrast(const Color(0xFFFFFFFF), sw.fill),
            greaterThanOrEqualTo(4.5),
            reason: p.id);
      }
    });

    test('en clair : la primaire DÉRIVÉE du lot 1 clair, qui porte le blanc',
        () {
      for (final p in kAllPalettes) {
        final sw = themeSwatches(p, Brightness.light);
        expect(sw.text, BrandContrast.lightText(p.primary), reason: p.id);
        expect(
            BrandContrast.contrast(const Color(0xFFFFFFFF), sw.fill),
            greaterThanOrEqualTo(4.5),
            reason: p.id);
      }
    });
  });

  group('appearanceSubtitle — l\'état réel', () {
    test('mode explicite', () {
      expect(
          appearanceSubtitle(
              paletteLabel: 'Indigo',
              mode: ThemeMode.light,
              resolved: Brightness.light,
              isFr: true),
          'Indigo · mode clair');
      expect(
          appearanceSubtitle(
              paletteLabel: 'Minuit',
              mode: ThemeMode.dark,
              resolved: Brightness.dark,
              isFr: true),
          'Minuit · mode sombre');
    });

    test('mode système : le mode RÉSOLU entre parenthèses', () {
      expect(
          appearanceSubtitle(
              paletteLabel: 'Ambre',
              mode: ThemeMode.system,
              resolved: Brightness.dark,
              isFr: true),
          'Ambre · mode système (sombre)');
    });
  });
}
