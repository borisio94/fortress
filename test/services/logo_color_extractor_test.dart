// Tests de LogoColorExtractor.extractForTheme — l'étape la plus
// algorithmique du pipeline « thème depuis logo ». On génère des PNG
// synthétiques (package image) pour piloter chaque branche :
//   * image colorée saturée → palette exploitable, non-monochrome
//   * image grise           → isMonochrome (bascule Midnight côté caller)
//   * bytes vides/invalides  → null (thème inchangé, pas de crash)
//
// Les images restent < 500 KB → pas de bascule compute() (isolate),
// donc le chemin synchrone est exercé directement. Les helpers HSL /
// WCAG sont privés ; on valide leur effet via le RÉSULTAT observable
// (ramp 7 stops, contraste, saturation).

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/services/logo_color_extractor.dart';
import 'package:image/image.dart' as img;

/// Génère un PNG uni de [w]×[h] rempli de (r,g,b).
Uint8List _solidPng(int r, int g, int b, {int w = 48, int h = 48}) {
  final image = img.Image(width: w, height: h);
  img.fill(image, color: img.ColorRgb8(r, g, b));
  return Uint8List.fromList(img.encodePng(image));
}

/// Génère un PNG bicolore (moitié gauche c1, moitié droite c2) — plus
/// proche d'un vrai logo qu'un aplat uni, pour exercer le clustering.
Uint8List _twoTonePng(
  (int, int, int) c1,
  (int, int, int) c2, {
  int w = 64,
  int h = 64,
}) {
  final image = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final c = x < w ~/ 2 ? c1 : c2;
      image.setPixelRgb(x, y, c.$1, c.$2, c.$3);
    }
  }
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  group('extractForTheme — entrées invalides', () {
    test('bytes vides → null', () async {
      final res = await LogoColorExtractor.extractForTheme(Uint8List(0));
      expect(res, isNull);
    });

    test('bytes non décodables → null (thème inchangé)', () async {
      final junk = Uint8List.fromList(List.filled(64, 0x42));
      final res = await LogoColorExtractor.extractForTheme(junk);
      expect(res, isNull);
    });
  });

  group('extractForTheme — logo monochrome', () {
    test('aplat gris → isMonochrome true', () async {
      final res =
          await LogoColorExtractor.extractForTheme(_solidPng(128, 128, 128));
      expect(res, isNotNull);
      expect(res!.isMonochrome, isTrue,
          reason: 'un gris pur a une saturation nulle');
    });

    test('noir + blanc → monochrome (aucune teinte)', () async {
      // Après filtrage des quasi-blancs/noirs, il peut ne rester aucune
      // couleur exploitable → soit monochrome, soit null. Les deux sont
      // des résultats acceptables (le caller laisse le thème ou bascule
      // Midnight). On vérifie surtout l'ABSENCE de palette colorée.
      final res = await LogoColorExtractor.extractForTheme(
          _twoTonePng((20, 20, 20), (235, 235, 235)));
      if (res != null) {
        expect(res.isMonochrome, isTrue);
      }
    });
  });

  group('extractForTheme — logo coloré', () {
    test('rouge saturé → palette non-monochrome avec ramp 7 stops', () async {
      final res =
          await LogoColorExtractor.extractForTheme(_solidPng(200, 30, 30));
      expect(res, isNotNull);
      expect(res!.isMonochrome, isFalse);
      // Ramp complet (sauf si fallback catalogue, qui fournit aussi 7 stops).
      expect(res.rampStops.keys.toSet(),
          containsAll(<int>{50, 100, 200, 400, 600, 800, 900}));
    });

    test('primary garde la dominante chromatique rouge', () async {
      final res =
          await LogoColorExtractor.extractForTheme(_solidPng(200, 30, 30));
      expect(res, isNotNull);
      final p = res!.primary;
      // Le canal rouge doit dominer franchement les deux autres, même
      // après ajustement de luminance via le ramp.
      expect(p.r, greaterThan(p.g));
      expect(p.r, greaterThan(p.b));
    });

    test('ramp ordonné du clair (50) au foncé (900)', () async {
      final res =
          await LogoColorExtractor.extractForTheme(_solidPng(40, 90, 200));
      expect(res, isNotNull);
      if (res!.isMonochrome || res.fellBackToCatalog) return; // n/a
      double lum(Color c) => 0.299 * c.r + 0.587 * c.g + 0.114 * c.b;
      final l50  = lum(res.rampStops[50]!);
      final l400 = lum(res.rampStops[400]!);
      final l900 = lum(res.rampStops[900]!);
      expect(l50, greaterThan(l400),
          reason: 'le stop 50 est plus clair que le 400');
      expect(l400, greaterThan(l900),
          reason: 'le stop 400 est plus clair que le 900');
    });

    test('contraste WCAG : 900 vs 50 ≥ 4.5 (texte lisible sur surface)',
        () async {
      final res =
          await LogoColorExtractor.extractForTheme(_solidPng(30, 120, 80));
      expect(res, isNotNull);
      // Que le résultat soit dérivé ou fallback catalogue, l'invariant
      // de lisibilité doit tenir : c'est la garantie principale de l'algo.
      final surface = res!.rampStops[50];
      final deep    = res.rampStops[900];
      expect(surface, isNotNull);
      expect(deep, isNotNull);
      expect(_contrast(deep!, surface!), greaterThanOrEqualTo(4.5));
    });
  });
}

// Ratio de contraste WCAG 2.x — reproduit pour la vérification de test.
double _contrast(Color a, Color b) {
  double rl(Color c) {
    double ch(double v) => v <= 0.03928
        ? v / 12.92
        : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
  }

  final la = rl(a), lb = rl(b);
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}
