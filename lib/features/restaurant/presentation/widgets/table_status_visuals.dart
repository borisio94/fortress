import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../domain/entities/restaurant_table.dart';

/// LA COULEUR d'un statut de table du plan de salle.
///
/// Séparé de `restaurant_table.dart` pour que le domaine reste du Dart pur
/// (26/09/2026) : le domaine dit DANS QUEL ÉTAT est une table, la
/// présentation dit à quoi il ressemble — même partage que
/// `service_tab_visuals.dart`. Rien de tout ceci n'est stocké : une table se
/// sérialise par la clé de son statut.
extension RestaurantTableStatusVisuals on RestaurantTableStatus {
  /// Couleur d'accent — liseré, bordure, point de légende. Résolue depuis les
  /// tokens sémantiques du thème (jamais de `Color(0xFF…)` en dur).
  Color color(AppSemanticColors s) => switch (this) {
        RestaurantTableStatus.libre     => s.success,
        RestaurantTableStatus.occupee   => s.warning,
        RestaurantTableStatus.addition  => s.danger,
        RestaurantTableStatus.reservee  => s.info,
      };

  /// Fond de carte — surface teintée du même token.
  Color surface(AppSemanticColors s) => switch (this) {
        RestaurantTableStatus.libre     => s.successSurface,
        RestaurantTableStatus.occupee   => s.warningSurface,
        RestaurantTableStatus.addition  => s.dangerSurface,
        // Pas de `infoSurface` dans AppSemanticColors → dérivé du token info,
        // ce qui reste cohérent en clair comme en sombre.
        RestaurantTableStatus.reservee  => s.info.withValues(alpha: 0.12),
      };
}
