// `textHint` EN SOMBRE (26/09/2026) — la dette de palette levée.
//
// L'ancien slate-500 (#64748B) ne faisait que 3,07:1 sur la carte sombre :
// sous le seuil AA d'un texte de 11 à 12 px (4,5:1), alors que `micro`,
// `captionHint` et `inputHint` l'emploient partout. La valeur est DÉRIVÉE :
// on avance de slate-500 vers `textSecondary` jusqu'au premier pas (0,60) qui
// tient 4,5:1 sur la PIRE surface sombre. Ce test vérifie la formule et ce
// qu'elle garantit, et que le mode clair n'a pas bougé.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/theme/app_colors.dart';
import 'package:fortress/core/theme/app_theme.dart';
import 'package:fortress/core/theme/brand_contrast.dart';
import 'package:fortress/core/theme/theme_palette.dart';

double c(Color a, Color b) => BrandContrast.contrast(a, b);

const _slate500 = Color(0xFF64748B);

void main() {
  tearDown(() => AppColors.applyBrightness(Brightness.light));

  Color hintIn(Brightness b) {
    AppColors.applyBrightness(b);
    return AppColors.textHint;
  }

  test('sa formule : lerp(slate-500, textSecondary, 0,60)', () {
    AppColors.applyBrightness(Brightness.dark);
    final derived = Color.lerp(_slate500, AppColors.textSecondary, 0.60)!;
    expect(AppColors.textHint.toARGB32(), derived.toARGB32());
    expect(AppColors.textHint, const Color(0xFF8190A6));
  });

  test('0,60 est le PREMIER pas qui tient : 0,55 échoue sur la carte', () {
    AppColors.applyBrightness(Brightness.dark);
    final before = Color.lerp(_slate500, AppColors.textSecondary, 0.55)!;
    expect(c(before, const Color(0xFF1E293B)), lessThan(4.5));
  });

  test('reste plus éteint que textSecondary', () {
    AppColors.applyBrightness(Brightness.dark);
    const card = Color(0xFF1E293B);
    expect(c(AppColors.textHint, card),
        lessThan(c(AppColors.textSecondary, card)));
  });

  test('le thème Material sombre porte la même valeur', () {
    final dark = hintIn(Brightness.dark);
    for (final p in kAllPalettes) {
      final t = AppTheme.dark(palette: p);
      expect(t.inputDecorationTheme.hintStyle?.color, dark, reason: p.id);
      expect(t.textTheme.labelSmall?.color, dark, reason: p.id);
    }
  });

  group('4,5:1 sur les surfaces sombres', () {
    // Le panneau de verre du restaurant : `#0B0F14` à 86 % sur le haut du
    // décor (`resto_surfaces.dart`, `RestoGlassPanel` et
    // `kRestoBackdropDarkTop`) — recopié ici, les deux sont privés.
    final restoGlass = Color.alphaBlend(
        const Color(0xFF0B0F14).withValues(alpha: 0.86),
        const Color(0xFF10161D));
    final surfaces = <(String, Color)>[
      ('fond de page', BrandContrast.kDarkBackground),
      ('verre du restaurant', restoGlass),
      for (final p in kAllPalettes) ...[
        ('carte ${p.id}', AppTheme.dark(palette: p).semantic.elevatedSurface),
        ('creusée ${p.id}', AppTheme.dark(palette: p).semantic.sunkenSurface),
      ],
    ];
    for (final (name, bg) in surfaces) {
      test(name, () {
        expect(c(hintIn(Brightness.dark), bg), greaterThanOrEqualTo(4.5));
      });
    }
  });

  // HORS garantie : la teinte de MARQUE (`brandSurface`). Aucun gris neutre
  // n'y tient — `textSecondary` lui-même y tombe à 4,07 (emerald) — : sur
  // elle, le texte s'écrit en `brandText`. Mesuré ici pour que ce trou reste
  // visible et ne soit pas découvert une seconde fois.
  test('sur la teinte de marque, même textSecondary échoue : brandText', () {
    AppColors.applyBrightness(Brightness.dark);
    final emerald = kAllPalettes.firstWhere((p) => p.id == 'emerald');
    final s = AppTheme.dark(palette: emerald).semantic;
    expect(c(AppColors.textSecondary, s.brandSurface), lessThan(4.5));
    expect(c(s.brandText, s.brandSurface), greaterThanOrEqualTo(4.5));
  });

  test('le mode clair n’a pas bougé : #5B6472, 5,98:1 sur blanc', () {
    final light = hintIn(Brightness.light);
    expect(light, const Color(0xFF5B6472));
    expect(c(light, Colors.white), closeTo(5.98, 0.01));
  });
}
