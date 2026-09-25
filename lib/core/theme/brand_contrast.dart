import 'dart:ui' show Color;

/// CONTRASTE DE LA COULEUR DE MARQUE — les valeurs sont DÉRIVÉES, jamais
/// choisies.
///
/// ─── POURQUOI CE FICHIER EXISTE ─────────────────────────────────────────────
///
/// En sombre, la primaire d'une palette sert à deux choses que NULLE couleur ne
/// peut faire à la fois :
///
///   • TEXTE, icône ou trait posé sur la carte sombre (`#1E293B`). Pour y tenir
///     4,5:1, sa luminance relative doit être ≥ 0,273.
///   • FOND sous un libellé blanc (bouton plein). Pour que le blanc y tienne
///     4,5:1, sa luminance doit être ≤ 0,183.
///
/// 0,273 > 0,183 : les deux conditions sont INCOMPATIBLES. Une seule valeur de
/// palette ne peut donc pas servir aux deux rôles — c'est pour cela qu'il en
/// existe plusieurs, calculées ici, UNE PAR USAGE :
///
///   • [darkText]       — la primaire éclaircie jusqu'à 4,5:1 sur la carte, la
///                        piste et le fond sombres. Sert `AppColors.primary` en
///                        sombre et la primaire du `ColorScheme` sombre.
///   • [darkBrandText]  — la même, tenue AUSSI sur `brandSurface` (la primaire
///                        à 20 % sur la carte). Sert `brand` et `brandText`,
///                        qui vivent par construction sur cette teinte.
///   • [fillUnderWhite] — la couleur assombrie jusqu'à ce que le blanc y tienne
///                        4,5:1. Sert le fond des boutons pleins du thème.
///
/// POURQUOI [darkText] N'INCLUT PAS LES TEINTES (décision du 25/09/2026) : les
/// inclure éclaircit la primaire des HUIT palettes, et les fonds peints à la
/// main en `AppColors.primary` sous du blanc (≈ 153 sites, lot 1b du backlog)
/// tomberaient à 2,2–2,8:1. Sans elles, seules Violet, Rose, Midnight et
/// Indigo bougent (blanc ≈ 3,2:1 dessus, compromis accepté). Le prix : le texte
/// en primaire posé sur `AppColors.primarySurface` reste à 3,4–3,96:1 — inscrit
/// au backlog lui aussi.
///
/// ⚠ NE PAS « SIMPLIFIER » EN REMETTANT UNE VALEUR DE PALETTE. C'est exactement
/// ce qu'il y avait avant (25/09/2026) : `AppColors.primary` valait la primaire
/// brute en sombre, et sur Midnight elle était IDENTIQUE à la carte — du texte à
/// 1,00:1, invisible, sur quelque 590 sites. Le fond des boutons valait
/// `primaryLight` : du blanc à moins de 2,7:1 sur six palettes sur huit.
///
/// ─── LA RÈGLE ────────────────────────────────────────────────────────────────
///
/// On part de la couleur de la palette et on la mélange vers le blanc (texte)
/// ou vers le noir (fond), par pas de 0,1 %, et on S'ARRÊTE AU SEUIL. Une
/// couleur déjà lisible sur toutes les surfaces de son usage n'est pas
/// touchée (Ocean, Emerald, Sunset, Amber pour [darkText]), les autres bougent
/// du minimum.
///
/// C'est aussi la seule approche qui couvre les palettes générées depuis un
/// LOGO (`LogoThemeBuilder`) : leurs couleurs sont arbitraires, personne ne
/// peut les mesurer à l'avance.
///
/// Fonctions pures, sans état, testées (`test/theme/brand_contrast_test.dart`).
abstract final class BrandContrast {
  /// Seuil AA d'un texte courant (WCAG 2.x, 1.4.3).
  static const double kMinTextContrast = 4.5;

  /// Surfaces SOMBRES sur lesquelles la primaire est lue. Ce sont les valeurs
  /// du thème sombre (`AppTheme._dSurface`, `_dScaffold`, `trackMuted`) —
  /// dupliquées ici pour que la fonction reste pure et testable seule.
  static const Color kDarkCard       = Color(0xFF1E293B);
  static const Color kDarkTrack      = Color(0xFF1F2937);
  static const Color kDarkBackground = Color(0xFF0F172A);

  /// Opacité de `brandSurface` : la primaire à 20 % sur la carte sombre
  /// (`AppSemanticColors.darkForBrand`).
  static const double kBrandSurfaceAlpha = 0.20;

  static const Color _white = Color(0xFFFFFFFF);
  static const Color _black = Color(0xFF000000);
  static const int _steps = 1000;

  /// Rapport de contraste WCAG entre deux couleurs opaques.
  static double contrast(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    final hi = la > lb ? la : lb;
    final lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  /// Le PIRE contraste de [c] sur l'ensemble des [surfaces].
  static double worstContrast(Color c, Iterable<Color> surfaces) =>
      surfaces.map((s) => contrast(c, s)).reduce((a, b) => a < b ? a : b);

  /// Mélange [base] vers le blanc (`towardWhite`) ou le noir, par pas de
  /// 0,1 %, jusqu'à ce que le pire contraste sur [surfaces] atteigne [min].
  /// S'arrête au premier pas qui passe : [base] est rendu tel quel s'il passe
  /// déjà. Termine toujours (le blanc ou le noir pur en dernier recours).
  static Color readableOn(
    Color base,
    Iterable<Color> surfaces, {
    bool towardWhite = true,
    double min = kMinTextContrast,
  }) {
    final target = towardWhite ? _white : _black;
    final opaque = base.withValues(alpha: 1);
    for (var i = 0; i <= _steps; i++) {
      final c = Color.lerp(opaque, target, i / _steps)!;
      if (worstContrast(c, surfaces) >= min) return c;
    }
    return target;
  }

  /// Teinte de marque posée sur la carte sombre (cf. [kBrandSurfaceAlpha]).
  static Color darkTint(Color primary, double alpha) =>
      Color.alphaBlend(primary.withValues(alpha: alpha), kDarkCard);

  /// Les surfaces sombres neutres : carte, piste, fond.
  static const List<Color> kDarkSurfaces = [
    kDarkCard,
    kDarkTrack,
    kDarkBackground,
  ];

  /// Variante TEXTE de la primaire en sombre : lisible à 4,5:1 sur la carte,
  /// la piste et le fond. PAS sur les teintes de marque — voir l'en-tête.
  static Color darkText(Color primary) => readableOn(primary, kDarkSurfaces);

  /// Variante TEXTE pour `brand` / `brandText` : comme [darkText], et tenue
  /// AUSSI sur `brandSurface`, calculée depuis la primaire BRUTE comme dans
  /// le thème.
  static Color darkBrandText(Color primary) => readableOn(primary, [
        ...kDarkSurfaces,
        darkTint(primary, kBrandSurfaceAlpha),
      ]);

  /// Fond sous un libellé BLANC : [base] assombri jusqu'à ce que le blanc y
  /// tienne 4,5:1. Rendu tel quel s'il tient déjà (Midnight, Violet en clair).
  static Color fillUnderWhite(Color base) =>
      readableOn(base, const [_white], towardWhite: false);
}
