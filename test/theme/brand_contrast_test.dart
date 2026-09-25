import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/theme/app_colors.dart';
import 'package:fortress/core/theme/app_theme.dart';
import 'package:fortress/core/theme/brand_contrast.dart';
import 'package:fortress/core/theme/theme_palette.dart';

/// Lot 1 — tokens de marque en sombre (25/09/2026).
///
/// Ces tests protègent la RÈGLE, pas des valeurs : ils vérifient les seuils
/// sur les huit palettes du catalogue ET sur des palettes « logo » arbitraires,
/// le cas que personne ne peut mesurer à l'avance.
void main() {
  const darkSurfaces = BrandContrast.kDarkSurfaces;
  const white = Color(0xFFFFFFFF);

  /// Palettes « logo » : ce que `LogoThemeBuilder` peut produire à partir
  /// d'une image quelconque. primaryLight = ramp[400], ici approché par la
  /// même couleur éclaircie — seul compte qu'elle soit arbitraire.
  ThemePalette logo(String id, int primary, int light) => ThemePalette(
        id: id,
        labelFr: id,
        labelEn: id,
        primary: Color(primary),
        primaryLight: Color(light),
        primaryDark: Color(primary),
        primarySurface: const Color(0xFFFFFFFF),
        previewGradient: const [],
      );

  final logos = <ThemePalette>[
    logo('logo_tres_sombre', 0xFF0B1020, 0xFF1A2238), // quasi noir bleuté
    logo('logo_noir', 0xFF050505, 0xFF141414),        // noir pur de logo
    logo('logo_tres_clair', 0xFFFFF4C2, 0xFFFFF9E0),  // jaune pâle
    logo('logo_desature', 0xFF8E8A86, 0xFFB5B1AD),    // gris taupe
    logo('logo_sature', 0xFFFF0000, 0xFFFF6666),      // rouge pur
    logo('logo_vert_fluo', 0xFF39FF14, 0xFF8CFF7A),   // très lumineux
  ];
  final all = [...kAllPalettes, ...logos];

  group('BrandContrast.darkText — texte lisible en sombre', () {
    for (final p in all) {
      test('${p.id} : ≥ 4,5:1 sur la carte, la piste et le fond', () {
        final t = BrandContrast.darkText(p.primary);
        expect(BrandContrast.worstContrast(t, darkSurfaces),
            greaterThanOrEqualTo(4.5));
      });
    }

    test('une couleur déjà lisible n\'est PAS touchée, les autres oui', () {
      for (final p in all) {
        final alreadyOk =
            BrandContrast.worstContrast(p.primary, darkSurfaces) >= 4.5;
        expect(BrandContrast.darkText(p.primary) == p.primary, alreadyOk,
            reason: p.id);
      }
    });

    test('le compromis accepté : seules Violet, Rose, Midnight et Indigo bougent',
        () {
      for (final p in kAllPalettes) {
        final moved = BrandContrast.darkText(p.primary) != p.primary;
        expect(moved, ['violet', 'rose', 'midnight', 'indigo'].contains(p.id),
            reason: p.id);
      }
    });

    test('Midnight : la primaire brute était IDENTIQUE à la carte (1,00:1)',
        () {
      final m = paletteById('midnight');
      expect(BrandContrast.contrast(m.primary, BrandContrast.kDarkCard),
          closeTo(1.0, 0.001));
      expect(
          BrandContrast.contrast(
              BrandContrast.darkText(m.primary), BrandContrast.kDarkCard),
          greaterThanOrEqualTo(4.5));
    });

    test('on s\'arrête AU seuil : un pas de moins ne passerait pas', () {
      final v = paletteById('violet');
      final t = BrandContrast.darkText(v.primary);
      expect(t, isNot(v.primary));
      // Revenir d'un pas vers la primaire brute repasse sous 4,5:1.
      final before = Color.lerp(t, v.primary, 0.01)!;
      expect(BrandContrast.worstContrast(before, darkSurfaces), lessThan(4.5));
    });
  });

  group('BrandContrast.darkBrandText — brand / brandText sur leur teinte', () {
    for (final p in all) {
      test('${p.id} : ≥ 4,5:1 sur les surfaces sombres ET sur brandSurface',
          () {
        final t = BrandContrast.darkBrandText(p.primary);
        expect(
            BrandContrast.worstContrast(t, [
              ...darkSurfaces,
              BrandContrast.darkTint(
                  p.primary, BrandContrast.kBrandSurfaceAlpha),
            ]),
            greaterThanOrEqualTo(4.5));
      });
    }
  });

  group('BrandContrast.fillUnderWhite — fond sous un libellé blanc', () {
    for (final p in all) {
      test('${p.id} : le blanc tient 4,5:1 sur le fond des boutons', () {
        final f = BrandContrast.fillUnderWhite(p.primaryLight);
        expect(BrandContrast.contrast(white, f), greaterThanOrEqualTo(4.5));
      });
    }

    test('Midnight : fond déjà sombre, rendu tel quel', () {
      final m = paletteById('midnight');
      expect(BrandContrast.fillUnderWhite(m.primaryLight), m.primaryLight);
    });
  });

  group('Les deux conditions sont incompatibles (pourquoi deux valeurs)', () {
    test('lisible sur la carte ⇒ le blanc ne tient plus dessus', () {
      for (final p in all) {
        final t = BrandContrast.darkText(p.primary);
        // Luminance ≥ ~0,273 pour le texte (4,5:1 sur la carte), ≤ 0,183
        // pour porter du blanc — calculés ici, pas recopiés.
        final textMin =
            4.5 * (BrandContrast.kDarkCard.computeLuminance() + 0.05) - 0.05;
        expect(textMin, greaterThan(1.05 / 4.5 - 0.05));
        expect(t.computeLuminance(), greaterThanOrEqualTo(textMin - 1e-9),
            reason: p.id);
        expect(BrandContrast.contrast(white, t), lessThan(4.5), reason: p.id);
      }
    });
  });

  group('AppSemanticColors.darkForBrand', () {
    for (final p in all) {
      test('${p.id} : brandText ≥ 4,5:1 sur brandSurface et sur la carte', () {
        final s = AppSemanticColors.darkForBrand(p.primary);
        expect(BrandContrast.contrast(s.brandText, s.brandSurface),
            greaterThanOrEqualTo(4.5));
        expect(BrandContrast.contrast(s.brandText, s.elevatedSurface),
            greaterThanOrEqualTo(4.5));
        expect(s.brand, s.brandText);
      });
    }
  });

  group('AppTheme.dark — le schéma et les boutons', () {
    for (final p in all) {
      test(p.id, () {
        final t = AppTheme.dark(palette: p);
        final cs = t.colorScheme;
        // La primaire du schéma se lit sur la carte…
        expect(BrandContrast.contrast(cs.primary, cs.surface),
            greaterThanOrEqualTo(4.5));
        // … et son contenu se lit sur elle.
        expect(BrandContrast.contrast(cs.onPrimary, cs.primary),
            greaterThanOrEqualTo(4.5));
        // Boutons pleins : blanc sur fond dérivé.
        for (final style in [
          t.elevatedButtonTheme.style!,
          t.filledButtonTheme.style!,
        ]) {
          final bg = style.backgroundColor!.resolve(<WidgetState>{})!;
          final fg = style.foregroundColor!.resolve(<WidgetState>{})!;
          expect(BrandContrast.contrast(fg, bg), greaterThanOrEqualTo(4.5));
        }
        // Bouton texte : lisible sur la carte.
        final tb = t.textButtonTheme.style!.foregroundColor!
            .resolve(<WidgetState>{})!;
        expect(BrandContrast.contrast(tb, cs.surface),
            greaterThanOrEqualTo(4.5));
        // Action d'un snack : lisible sur SON fond.
        expect(
            BrandContrast.contrast(t.snackBarTheme.actionTextColor!,
                t.snackBarTheme.backgroundColor!),
            greaterThanOrEqualTo(4.5));
      });
    }
  });

  group('AppColors.primary — getter adaptatif', () {
    tearDown(() {
      AppColors.applyBrightness(Brightness.light);
      AppColors.applyPalette(kDefaultPalette);
    });

    test('en CLAIR : la valeur de la palette, inchangée', () {
      for (final p in kAllPalettes) {
        AppColors.applyPalette(p);
        AppColors.applyBrightness(Brightness.light);
        expect(AppColors.primary, p.primary, reason: p.id);
      }
    });

    test('en SOMBRE : la variante texte, ≥ 4,5:1 sur la carte', () {
      for (final p in all) {
        AppColors.applyPalette(p);
        AppColors.applyBrightness(Brightness.dark);
        expect(AppColors.primary, BrandContrast.darkText(p.primary),
            reason: p.id);
        expect(
            BrandContrast.contrast(AppColors.primary, BrandContrast.kDarkCard),
            greaterThanOrEqualTo(4.5),
            reason: p.id);
        AppColors.applyBrightness(Brightness.light);
      }
    });

    test('changer de palette EN SOMBRE met la variante à jour', () {
      AppColors.applyBrightness(Brightness.dark);
      AppColors.applyPalette(paletteById('violet'));
      final violet = AppColors.primary;
      AppColors.applyPalette(paletteById('midnight'));
      expect(AppColors.primary, isNot(violet));
      expect(AppColors.primary,
          BrandContrast.darkText(paletteById('midnight').primary));
    });
  });
}
