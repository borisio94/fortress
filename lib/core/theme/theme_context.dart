import 'package:flutter/material.dart';

import 'app_theme.dart';

/// Raccourcis d'accès aux tokens de thème depuis un `BuildContext`.
///
/// Évite le verbeux `Theme.of(context).colorScheme` /
/// `Theme.of(context).extension<AppSemanticColors>()!` à chaque usage
/// et — surtout — pousse les widgets à lire les tokens DYNAMIQUES du
/// thème (qui suivent clair/sombre) plutôt que des couleurs fixes
/// (`Colors.white`, `AppColors.surface`) qui cassent en mode sombre.
///
/// Usage :
/// ```dart
/// Container(color: context.colors.surface)        // fond de card
/// Text('x', style: TextStyle(color: context.colors.onSurface))
/// Border.all(color: context.semantic.borderSubtle)
/// ```
extension ThemeContext on BuildContext {
  /// `ColorScheme` du thème courant — `surface`, `onSurface`, `primary`…
  /// `surface` est blanc en clair, slate sombre en sombre.
  ColorScheme get colors => Theme.of(this).colorScheme;

  /// Tokens sémantiques Fortress (success/warning/danger + surfaces
  /// élevées + bordures). Déjà déclinés clair/sombre par la factory.
  AppSemanticColors get semantic => Theme.of(this).semantic;
}
