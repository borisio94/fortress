import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/theme/app_theme.dart';
import 'package:fortress/core/theme/brand_contrast.dart';
import 'package:fortress/features/restaurant/presentation/widgets/resto_surfaces.dart';

/// Barre du haut du restaurant (25/09/2026) : opaque, et de la MÊME famille
/// que le bloc de contenu — plus le slate des cartes (#1E293B) en sombre.
void main() {
  Future<({Color bar, Color glass, Color surface})> resolve(
      WidgetTester tester, ThemeData theme) async {
    late ({Color bar, Color glass, Color surface}) out;
    await tester.pumpWidget(MaterialApp(
      theme: theme,
      home: Builder(builder: (context) {
        out = (
          bar: restoChromeOpaque(context),
          glass: restoGlassFill(context),
          surface: Theme.of(context).colorScheme.surface,
        );
        return const SizedBox();
      }),
    ));
    return out;
  }

  testWidgets('sombre : opaque, quasi noir, confondu avec le contenu',
      (tester) async {
    final r = await resolve(tester, AppTheme.dark());
    expect(r.bar.a, 1.0, reason: 'opaque — l\'intention de 080bcf1');
    expect(r.bar, isNot(r.surface), reason: 'plus le slate des cartes');
    // Le contenu : le même verre composé sur le décor.
    final content = Color.alphaBlend(r.glass, kRestoBackdropDarkTop);
    expect(BrandContrast.contrast(r.bar, content), lessThan(1.02));
    // L'ancien écart : 1,30:1 contre #1E293B.
    expect(BrandContrast.contrast(r.surface, content), greaterThan(1.25));
  });

  testWidgets('clair : colorScheme.surface, strictement inchangé',
      (tester) async {
    final r = await resolve(tester, AppTheme.light());
    expect(r.bar, r.surface);
  });
}
