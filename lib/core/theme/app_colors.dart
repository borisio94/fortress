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

  /// Palette claire (light) brute — sert de base à `_primarySurface`
  /// et à la dérivation sombre.
  static ThemePalette _palette = kDefaultPalette;

  /// Met à jour les couleurs primaires runtime. Appelé au démarrage et à
  /// chaque changement de palette dans les paramètres.
  static void applyPalette(ThemePalette p) {
    _palette        = p;
    _primary        = p.primary;
    _primaryLight   = p.primaryLight;
    _primaryDark    = p.primaryDark;
    _refreshPrimarySurface();
  }

  // ── Brightness runtime (mode clair / sombre) ───────────────────────────────
  // Les tokens de SURFACE (surface/background/inputFill/inputBorder/divider)
  // et `primarySurface` ne sont plus des constantes : ils suivent le mode
  // EFFECTIVEMENT affiché. `app.dart` appelle [applyBrightness] avant de
  // construire l'UI, avec le brightness résolu (themeMode + plateforme).
  // Les widgets qui lisent `AppColors.surface` obtiennent ainsi la bonne
  // couleur en sombre sans devoir passer par `Theme.of(context)`.
  static bool _isDark = false;

  static void applyBrightness(Brightness b) {
    final dark = b == Brightness.dark;
    if (dark == _isDark) return;
    _isDark = dark;
    _refreshPrimarySurface();
  }

  static bool get isDark => _isDark;

  /// `primarySurface` = teinte douce du primary. En clair on prend la
  /// valeur de la palette ; en sombre on mélange le primary à ~16 % sur
  /// la surface slate (sinon le selected-state du drawer reste blanc vif).
  static void _refreshPrimarySurface() {
    _primarySurface = _isDark
        ? Color.alphaBlend(
            _palette.primary.withValues(alpha: 0.22), const Color(0xFF1E293B))
        : _palette.primarySurface;
  }

  // ── Couleurs fixes (indépendantes du thème) ────────────────────────────────
  static const secondary = Color(0xFF10B981);
  static const error     = Color(0xFFEF4444);
  static const warning   = Color(0xFFF59E0B);
  static const info      = Color(0xFF3B82F6);

  // ── Surfaces brightness-aware (getters, plus des const) ────────────────────
  static const _surfaceLight     = Color(0xFFFFFFFF);
  static const _surfaceDark      = Color(0xFF1E293B);
  static const _backgroundLight  = Color(0xFFF8F7FC);
  static const _backgroundDark   = Color(0xFF0F172A);
  static const _inputFillLight   = Color(0xFFF3F4F6);
  static const _inputFillDark    = Color(0xFF334155);
  static const _borderLight      = Color(0xFFE5E7EB);
  static const _borderDark       = Color(0xFF334155);

  static Color get surface     => _isDark ? _surfaceDark    : _surfaceLight;
  static Color get background  => _isDark ? _backgroundDark : _backgroundLight;
  static Color get inputFill   => _isDark ? _inputFillDark  : _inputFillLight;
  static Color get inputBorder => _isDark ? _borderDark     : _borderLight;
  static Color get divider     => _isDark ? _borderDark     : _borderLight;

  // Texte PRINCIPAL adaptatif (brightness-aware) — pendant de `colorScheme
  // .onSurface` mais lisible sans `context`. Remplace les `Color(0xFF111827)`
  // / `Color(0xFF0F172A)` posés en dur sur des textes/icônes : quasi-noir en
  // clair, quasi-blanc (slate-100) en sombre.
  static const _onSurfaceLight = Color(0xFF111827);
  static const _onSurfaceDark  = Color(0xFFF1F5F9);
  static Color get onSurface => _isDark ? _onSurfaceDark : _onSurfaceLight;

  // ── Textes (brightness-aware) ───────────────────────────────────────────────
  // Ces 3 tokens sont désormais des GETTERS qui suivent le mode clair/sombre
  // (comme surface/background/onSurface). Un `color: AppColors.textPrimary`
  // posé en dur devient donc lisible en sombre sans passer par le context.
  // Valeurs sombres alignées sur le textTheme de `AppTheme.dark`
  // (_dTextPrimary / _dTextSecondary / _dTextHint) pour une cohérence stricte.
  //
  // Conséquence : ils ne sont plus utilisables dans une expression `const`.
  // Les échelons `AppTextStyles.*Secondary` / `*Hint` qui les consomment sont
  // donc devenus des getters eux aussi (cf. app_text_styles.dart).
  static const _textPrimaryLight   = Color(0xFF111827);
  static const _textPrimaryDark    = Color(0xFFF1F5F9); // slate-100
  static const _textSecondaryLight = Color(0xFF4B5563); // gray-600 (~7:1 en clair)
  static const _textSecondaryDark  = Color(0xFF94A3B8); // slate-400 (lisible sur slate)
  static const _textHintLight      = Color(0xFF5B6472);
  static const _textHintDark       = Color(0xFF64748B); // slate-500

  static Color get textPrimary   => _isDark ? _textPrimaryDark   : _textPrimaryLight;
  static Color get textSecondary => _isDark ? _textSecondaryDark : _textSecondaryLight;
  static Color get textHint      => _isDark ? _textHintDark      : _textHintLight;

  static const google   = Color(0xFFEA4335);
  static const facebook = Color(0xFF1877F2);
  static const apple    = Color(0xFF000000);

  /// Vert officiel WhatsApp — couleur de marque (identique clair/sombre),
  /// utilisée par les CTA « partager sur WhatsApp ». Nommée ici pour éviter
  /// les `Color(0xFF25D366)` dispersés.
  static const whatsapp = Color(0xFF25D366);

  /// Palette stable utilisée pour dériver une couleur identifiable par
  /// hash du nom de variante quand le champ `variant.color` n'est pas
  /// renseigné. 12 teintes distinctes pour minimiser les collisions
  /// visuelles dans la grille produits.
  static const variantPalette = <Color>[
    Color(0xFFEF4444), Color(0xFFF97316), Color(0xFFEAB308),
    Color(0xFF84CC16), Color(0xFF22C55E), Color(0xFF14B8A6),
    Color(0xFF06B6D4), Color(0xFF3B82F6), Color(0xFF6366F1),
    Color(0xFF8B5CF6), Color(0xFFD946EF), Color(0xFFEC4899),
  ];
}
