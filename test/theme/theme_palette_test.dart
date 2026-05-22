// Tests purs de la sérialisation ThemePalette + du builder de palette
// depuis logo. Aucune dépendance Hive : on teste toJson/fromJson (round-
// trip) et LogoThemeBuilder.buildFromLogo (mapping LogoPalette →
// ThemePalette + branches monochrome / fallback catalogue).
//
// Enjeu : la palette générée depuis un logo persiste son JSON dans Hive.
// Si le round-trip perd une couleur, le thème de l'utilisateur casse au
// reload navigateur (couleurs noires / fallback Violet silencieux).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/services/logo_color_extractor.dart';
import 'package:fortress/core/theme/logo_theme_builder.dart';
import 'package:fortress/core/theme/theme_palette.dart';

void main() {
  group('ThemePalette round-trip JSON', () {
    test('toJson → fromJson préserve toutes les couleurs', () {
      const original = ThemePalette(
        id: 'logo_generated',
        labelFr: 'Votre logo',
        labelEn: 'Your logo',
        primary:        Color(0xFF123456),
        primaryLight:   Color(0xFFAABBCC),
        primaryDark:    Color(0xFF001122),
        primarySurface: Color(0xFFF0F0F0),
        previewGradient: [Color(0xFF123456), Color(0xFFAABBCC)],
      );

      final back = ThemePalette.fromJson(original.toJson());

      expect(back.id, original.id);
      expect(back.labelFr, original.labelFr);
      expect(back.primary, original.primary);
      expect(back.primaryLight, original.primaryLight);
      expect(back.primaryDark, original.primaryDark);
      expect(back.primarySurface, original.primarySurface);
      expect(back.previewGradient.length, 2);
      expect(back.previewGradient[0], const Color(0xFF123456));
      expect(back.previewGradient[1], const Color(0xFFAABBCC));
    });

    test('fromJson tolère un previewGradient absent', () {
      final json = {
        'id': 'logo_generated',
        'primary':        0xFF112233,
        'primaryLight':   0xFF223344,
        'primaryDark':    0xFF001122,
        'primarySurface': 0xFFFFFFFF,
        // pas de previewGradient ni labels
      };
      final p = ThemePalette.fromJson(json);
      expect(p.previewGradient, isEmpty);
      // labels par défaut appliqués
      expect(p.labelFr, 'Votre logo');
      expect(p.primary, const Color(0xFF112233));
    });
  });

  group('paletteById', () {
    test('id connu → palette correspondante', () {
      expect(paletteById('midnight').id, 'midnight');
      expect(paletteById('ocean').id, 'ocean');
    });

    test('id inconnu → fallback Violet (défaut)', () {
      expect(paletteById('logo_generated').id, 'violet',
          reason: 'logo_generated n\'est pas dans kAllPalettes');
      expect(paletteById('does_not_exist').id, 'violet');
    });
  });

  group('LogoThemeBuilder.buildFromLogo', () {
    LogoPalette palette({
      Color primary = const Color(0xFF2E7D32),
      Color secondary = const Color(0xFF66BB6A),
      bool monochrome = false,
      bool fellBack = false,
      String? fallbackId,
      Map<int, Color>? ramp,
    }) =>
        LogoPalette(
          primary: primary,
          secondary: secondary,
          rampStops: ramp ??
              const {
                50:  Color(0xFFE8F5E9),
                100: Color(0xFFC8E6C9),
                200: Color(0xFFA5D6A7),
                400: Color(0xFF66BB6A),
                600: Color(0xFF43A047),
                800: Color(0xFF2E7D32),
                900: Color(0xFF1B5E20),
              },
          isMonochrome: monochrome,
          fellBackToCatalog: fellBack,
          fallbackPaletteId: fallbackId,
        );

    test('cas normal → id logo_generated + couleurs mappées', () {
      final theme = LogoThemeBuilder.buildFromLogo(palette());
      expect(theme.id, LogoThemeBuilder.generatedId);
      expect(theme.id, 'logo_generated');
      // primary = couleur logo ; surface = ramp[50] ; dark = ramp[800].
      expect(theme.primary, const Color(0xFF2E7D32));
      expect(theme.primaryLight, const Color(0xFF66BB6A)); // ramp[400]
      expect(theme.primaryDark, const Color(0xFF2E7D32));  // ramp[800]
      expect(theme.primarySurface, const Color(0xFFE8F5E9)); // ramp[50]
      // gradient bicolore primary → secondary
      expect(theme.previewGradient.first, const Color(0xFF2E7D32));
      expect(theme.previewGradient.last,  const Color(0xFF66BB6A));
    });

    test('logo monochrome → palette Midnight (pas logo_generated)', () {
      final theme = LogoThemeBuilder.buildFromLogo(palette(monochrome: true));
      expect(theme.id, 'midnight');
    });

    test('fallback catalogue → palette du catalogue correspondante', () {
      final theme = LogoThemeBuilder.buildFromLogo(
          palette(fellBack: true, fallbackId: 'ocean'));
      expect(theme.id, 'ocean');
    });

    test('ramp vide → primary brut sur les 4 emplacements (pas de crash)', () {
      final theme = LogoThemeBuilder.buildFromLogo(palette(
        primary: const Color(0xFF884499),
        ramp: const {},
      ));
      expect(theme.id, 'logo_generated');
      expect(theme.primary, const Color(0xFF884499));
      // primaryLight / primaryDark retombent sur primary quand ramp absent.
      expect(theme.primaryLight, const Color(0xFF884499));
      expect(theme.primaryDark, const Color(0xFF884499));
    });
  });
}
