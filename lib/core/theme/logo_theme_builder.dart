import 'package:flutter/material.dart';

import '../services/logo_color_extractor.dart';
import 'theme_palette.dart';

/// Construit une `ThemePalette` à partir d'une `LogoPalette` extraite
/// d'un logo de boutique. Le résultat conserve la même interface que
/// les palettes prédéfinies `kAllPalettes` — aucune modification
/// d'`AppColors` / `AppTheme` n'est requise.
///
/// La palette générée porte l'id réservé `'logo_generated'` ; le
/// `ThemePaletteNotifier` la détecte au boot et hydrate depuis le
/// cache Hive (`logo_palette_cache`) au lieu de retomber sur Violet.
class LogoThemeBuilder {
  const LogoThemeBuilder._();

  /// Id réservé aux palettes générées dynamiquement depuis un logo —
  /// distinct de toutes les ids du catalogue `kAllPalettes`.
  static const String generatedId = 'logo_generated';

  static const String _labelFr = 'Votre logo';
  static const String _labelEn = 'Your logo';

  /// Construit la palette à partir de [logo]. Si le logo est
  /// monochrome ou si l'extraction a basculé sur un fallback
  /// catalogue, on retourne la palette correspondante de
  /// `kAllPalettes` plutôt qu'une palette générée — assure une
  /// expérience cohérente (l'utilisateur peut quand même la
  /// re-sélectionner depuis le sélecteur, mais elle n'est PAS
  /// taguée « Votre logo »).
  static ThemePalette buildFromLogo(LogoPalette logo) {
    if (logo.isMonochrome) {
      // Spec : monochrome → Midnight. Le caller affiche aussi un snack.
      return paletteById('midnight');
    }
    if (logo.fellBackToCatalog && logo.fallbackPaletteId != null) {
      return paletteById(logo.fallbackPaletteId!);
    }
    final ramp = logo.rampStops;
    // Sécurité : si le ramp est vide (cas non prévu), on retombe sur
    // primary brut pour les 4 emplacements — l'UI reste fonctionnelle.
    final primary       = logo.primary;
    final primaryLight  = ramp[400] ?? logo.primary;
    final primaryDark   = ramp[800] ?? logo.primary;
    final primarySurface = ramp[50] ?? Colors.white;
    return ThemePalette(
      id:               generatedId,
      labelFr:          _labelFr,
      labelEn:          _labelEn,
      primary:          primary,
      primaryLight:     primaryLight,
      primaryDark:      primaryDark,
      primarySurface:   primarySurface,
      // Gradient bicolore primary → secondary pour le preview du sélecteur.
      previewGradient: [logo.primary, logo.secondary],
    );
  }
}
