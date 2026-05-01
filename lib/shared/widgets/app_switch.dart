import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';

// ─────────────────────────────────────────────────────────────────────────────
// AppSwitch — Switch personnalisé Fortress
//
// Comportement visuel :
//   - Inactif : track gris clair, thumb blanc
//   - Actif   : track violet TRÈS atténué (10% opacité), thumb violet plein
//
// Remplacement direct du Switch Material qui colore tout en violet
// ─────────────────────────────────────────────────────────────────────────────

class AppSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Color? activeColor;

  const AppSwitch({
    super.key,
    required this.value,
    this.onChanged,
    this.activeColor,
  });

  @override
  Widget build(BuildContext context) {
    final color = activeColor ?? AppColors.primary;
    return Switch(
      value: value,
      onChanged: onChanged,
      // Thumb : violet quand actif, blanc quand inactif
      thumbColor: WidgetStateProperty.resolveWith<Color>((states) {
        if (states.contains(WidgetState.selected)) return color;
        return Colors.white;
      }),
      // Track : violet très atténué quand actif, gris clair quand inactif
      trackColor: WidgetStateProperty.resolveWith<Color>((states) {
        if (states.contains(WidgetState.selected)) {
          return color.withOpacity(0.25);
        }
        return const Color(0xFFE5E7EB);
      }),
      // Bordure du track
      trackOutlineColor: WidgetStateProperty.resolveWith<Color>((states) {
        if (states.contains(WidgetState.selected)) {
          return color.withOpacity(0.4);
        }
        return const Color(0xFFD1D5DB);
      }),
      trackOutlineWidth: WidgetStateProperty.all(1.0),
      // Pas d'overlay / splash violet sur le thumb
      overlayColor: WidgetStateProperty.resolveWith<Color>((states) {
        if (states.contains(WidgetState.pressed)) {
          return color.withOpacity(0.1);
        }
        return Colors.transparent;
      }),
      splashRadius: 16,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}