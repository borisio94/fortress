import 'package:flutter/material.dart';
import 'theme_palette.dart';

/// Couleurs globales de l'application.
///
/// Les couleurs `primary*` sont **runtime-mutable** via [AppColors.applyPalette]
/// — elles reflètent la palette actuellement sélectionnée par l'utilisateur
/// (voir `themePaletteProvider`). Comme ce ne sont plus des constantes, elles
/// ne peuvent plus être utilisées dans des expressions `const`.
///
/// Les couleurs non-palette (error, warning, surfaces, textes…) restent des
/// constantes car elles ne dépendent pas du thème choisi.
class AppColors {
  // ── Palette active (runtime) ───────────────────────────────────────────────
  static Color _primary        = kDefaultPalette.primary;
  static Color _primaryLight   = kDefaultPalette.primaryLight;
  static Color _primaryDark    = kDefaultPalette.primaryDark;
  static Color _primarySurface = kDefaultPalette.primarySurface;

  static Color get primary        => _primary;
  static Color get primaryLight   => _primaryLight;
  static Color get primaryDark    => _primaryDark;
  static Color get primarySurface => _primarySurface;

  /// Met à jour les couleurs primaires runtime. Appelé au démarrage et à
  /// chaque changement de palette dans les paramètres.
  static void applyPalette(ThemePalette p) {
    _primary        = p.primary;
    _primaryLight   = p.primaryLight;
    _primaryDark    = p.primaryDark;
    _primarySurface = p.primarySurface;
  }

  // ── Couleurs fixes (ne dépendent pas du thème) ─────────────────────────────
  static const secondary = Color(0xFF10B981);
  static const error     = Color(0xFFEF4444);
  static const warning   = Color(0xFFF59E0B);
  static const info      = Color(0xFF3B82F6);

  static const surface      = Color(0xFFFFFFFF);
  static const background   = Color(0xFFF8F7FC);
  static const inputFill    = Color(0xFFF3F4F6);
  static const inputBorder  = Color(0xFFE5E7EB);

  static const textPrimary   = Color(0xFF111827);
  static const textSecondary = Color(0xFF6B7280);
  // WCAG AA : #6B7280 atteint 5.5:1 sur fond blanc (vs 3:1 pour #9CA3AF).
  static const textHint      = Color(0xFF6B7280);

  static const google   = Color(0xFFEA4335);
  static const facebook = Color(0xFF1877F2);
  static const apple    = Color(0xFF000000);

  static const divider = Color(0xFFE5E7EB);
}
