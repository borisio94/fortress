// LES QUATRE TOKENS DU RENDU COLORÉ (26/09/2026) — `sunkenSurface`,
// `stateOutline`, `stateShadow`, `onStateFill`, sur les huit palettes du
// catalogue, en clair et en sombre. Ils sont DÉRIVÉS : ce test vérifie leur
// formule et ce qu'elle garantit, pas une valeur réglée à la main.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/theme/app_theme.dart';
import 'package:fortress/core/theme/brand_contrast.dart';
import 'package:fortress/core/theme/theme_palette.dart';

double c(Color a, Color b) => BrandContrast.contrast(a, b);

void main() {
  final themes = [
    for (final p in kAllPalettes) ...[
      (p.id, 'clair', AppTheme.light(palette: p)),
      (p.id, 'sombre', AppTheme.dark(palette: p)),
    ],
  ];

  test('huit palettes, deux modes', () {
    expect(kAllPalettes, hasLength(8));
  });

  for (final (id, mode, t) in themes) {
    group('$id, $mode', () {
      final sem = t.semantic;
      final cs = t.colorScheme;
      final card = sem.elevatedSurface;

      test('la surface creusée est PLUS SOMBRE que la carte, et se voit', () {
        final sunken = sem.sunkenSurface;
        expect(sunken.computeLuminance(), lessThan(card.computeLuminance()));
        expect(c(card, sunken), greaterThanOrEqualTo(1.10));
      });

      test('sa formule : vers borderSubtle en clair, vers le fond de page en '
          'sombre', () {
        expect(
            sem.sunkenSurface,
            mode == 'clair'
                ? Color.lerp(card, sem.borderSubtle, 0.5)
                : Color.lerp(card, BrandContrast.kDarkBackground, 0.75));
      });

      test('les textes du bloc creusé tiennent 4,5:1', () {
        for (final (name, fg) in [
          ('texte', cs.onSurface),
          ('texte secondaire', cs.onSurfaceVariant),
          ('marque', sem.brandText),
          ('payé', sem.successText),
          ('en attente', sem.warningText),
        ]) {
          expect(c(fg, sem.sunkenSurface), greaterThanOrEqualTo(4.5),
              reason: name);
        }
      });

      test('un fond plein d’état porte son texte à 4,5:1 au moins', () {
        for (final (name, fill) in [
          ('danger', sem.danger),
          ('warning', sem.warning),
          ('success', sem.success),
          ('info', sem.info),
          ('primaire', cs.primary),
        ]) {
          expect(c(sem.onStateFill(fill), fill), greaterThanOrEqualTo(4.5),
              reason: name);
        }
      });

      test('contour et ombre : la couleur de l’état, à leur opacité', () {
        final outline = sem.stateOutline(sem.warning);
        expect(outline.a, closeTo(kStateOutlineAlpha, 0.01));
        expect(outline.withValues(alpha: 1), sem.warning.withValues(alpha: 1));
        final shadow = sem.stateShadow(sem.danger).single;
        expect(shadow.color.a, closeTo(kStateShadowAlpha, 0.01));
      });
    });
  }
}
