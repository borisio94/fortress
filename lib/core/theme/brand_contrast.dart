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

  // ─── MODE CLAIR (lot 1 clair, 26/09/2026) ─────────────────────────────────
  //
  // En clair, les deux usages NE S'OPPOSENT PAS : être lisible SUR le blanc et
  // PORTER du blanc exigent tous deux une primaire assez FONCÉE. Une seule
  // valeur dérivée sert donc les deux — texte, icône, trait ET fond de bouton.
  //
  // Mesuré avant : Ocean 2,77:1 sur blanc, Emerald 2,54, Sunset 2,80, Amber
  // 3,19, Rose 3,53 — texte ET libellé blanc des boutons sous le seuil. Après :
  // ces cinq palettes foncent de 21 à 32 % (≈ la nuance « 700 » de leur
  // teinte) ; Violet, Midnight et Indigo ne bougent pas.

  /// Surfaces CLAIRES sur lesquelles la primaire est lue (valeurs du thème
  /// clair, dupliquées pour garder la fonction pure) : carte, fond de page.
  static const Color kLightCard       = Color(0xFFFFFFFF);
  static const Color kLightBackground = Color(0xFFF8F7FC);

  /// Opacité du verre clair du restaurant (`restoGlassFill`), posé sur le fond.
  static const double kLightGlassAlpha = 0.91;

  /// Teintes de marque sur lesquelles un TEXTE de marque se pose en clair :
  /// sélection, pastille, bouton d'état (10 à 14 %), `brandSurface` (10 %).
  static const List<double> kLightTintAlphas = [0.10, 0.12, 0.14];

  /// Toutes les surfaces claires d'un texte de marque, teintes comprises —
  /// chaque teinte sur la carte ET sur le fond (le plus sombre des deux est le
  /// pire cas).
  static List<Color> lightSurfaces(Color primary) => [
        kLightCard,
        kLightBackground,
        Color.alphaBlend(
            _white.withValues(alpha: kLightGlassAlpha), kLightBackground),
        for (final a in kLightTintAlphas) ...[
          Color.alphaBlend(primary.withValues(alpha: a), kLightCard),
          Color.alphaBlend(primary.withValues(alpha: a), kLightBackground),
        ],
      ];

  /// LA primaire du mode clair : [primary] assombrie jusqu'à 4,5:1 sur la
  /// carte, le fond, le verre, les teintes de la couleur BRUTE (`brandSurface`)
  /// ET les teintes d'ELLE-MÊME. Rendue telle quelle si elle tient déjà
  /// (Violet, Midnight, Indigo). Le blanc y tient alors aussi : elle sert le
  /// texte comme le fond des boutons.
  ///
  /// POURQUOI SES PROPRES TEINTES : l'application teinte avec la valeur
  /// DÉRIVÉE (`AppColors.primary.withValues(alpha: 0.1)` sous un texte en
  /// `AppColors.primary`, sélection du menu latéral…). Calculée sur les seules
  /// teintes brutes, Ocean tombait à 4,37:1 sur sa sélection à 12 % — mesuré
  /// par `brand_contrast_test`. Le candidat change à chaque pas, ses teintes
  /// aussi : d'où la boucle propre plutôt que [readableOn].
  static Color lightText(Color primary) {
    final base = primary.withValues(alpha: 1);
    final fixed = lightSurfaces(base);
    for (var i = 0; i <= _steps; i++) {
      final c = Color.lerp(base, _black, i / _steps)!;
      final surfaces = [
        ...fixed,
        for (final a in kLightTintAlphas) ...[
          Color.alphaBlend(c.withValues(alpha: a), kLightCard),
          Color.alphaBlend(c.withValues(alpha: a), kLightBackground),
        ],
      ];
      if (worstContrast(c, surfaces) >= kMinTextContrast) return c;
    }
    return _black;
  }

  /// Fond sous un libellé BLANC : [base] assombri jusqu'à ce que le blanc y
  /// tienne 4,5:1. Rendu tel quel s'il tient déjà (Midnight, Violet en clair).
  static Color fillUnderWhite(Color base) =>
      readableOn(base, const [_white], towardWhite: false);
}
