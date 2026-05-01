import 'package:flutter/material.dart';
import 'app_colors.dart';
import 'theme_palette.dart';

/// Couleurs sémantiques exposées via `Theme.of(context).extension<...>()`.
/// Permet aux pages d'utiliser `theme.semantic.success` plutôt que des
/// `Color(0xFF...)` hardcodés ou des références directes à `AppColors`.
@immutable
class AppSemanticColors extends ThemeExtension<AppSemanticColors> {
  final Color success;
  final Color warning;
  final Color danger;
  final Color info;
  /// Surface dédiée aux KPI / pills / cards. Plus marquée que `surface`.
  final Color elevatedSurface;
  /// Couleur de bordure douce pour les cards et séparateurs.
  final Color borderSubtle;
  /// Couleur d'arrière-plan pour les barres de progression neutres.
  final Color trackMuted;

  const AppSemanticColors({
    required this.success,
    required this.warning,
    required this.danger,
    required this.info,
    required this.elevatedSurface,
    required this.borderSubtle,
    required this.trackMuted,
  });

  @override
  AppSemanticColors copyWith({
    Color? success,
    Color? warning,
    Color? danger,
    Color? info,
    Color? elevatedSurface,
    Color? borderSubtle,
    Color? trackMuted,
  }) => AppSemanticColors(
    success:         success         ?? this.success,
    warning:         warning         ?? this.warning,
    danger:          danger          ?? this.danger,
    info:            info            ?? this.info,
    elevatedSurface: elevatedSurface ?? this.elevatedSurface,
    borderSubtle:    borderSubtle    ?? this.borderSubtle,
    trackMuted:      trackMuted      ?? this.trackMuted,
  );

  @override
  AppSemanticColors lerp(ThemeExtension<AppSemanticColors>? other, double t) {
    if (other is! AppSemanticColors) return this;
    return AppSemanticColors(
      success:         Color.lerp(success,         other.success,         t)!,
      warning:         Color.lerp(warning,         other.warning,         t)!,
      danger:          Color.lerp(danger,          other.danger,          t)!,
      info:            Color.lerp(info,            other.info,            t)!,
      elevatedSurface: Color.lerp(elevatedSurface, other.elevatedSurface, t)!,
      borderSubtle:    Color.lerp(borderSubtle,    other.borderSubtle,    t)!,
      trackMuted:      Color.lerp(trackMuted,      other.trackMuted,      t)!,
    );
  }

  static const light = AppSemanticColors(
    success:         Color(0xFF10B981),
    warning:         Color(0xFFF59E0B),
    danger:          Color(0xFFEF4444),
    info:            Color(0xFF3B82F6),
    elevatedSurface: Color(0xFFFFFFFF),
    borderSubtle:    Color(0xFFE5E7EB),
    trackMuted:      Color(0xFFF3F4F6),
  );

  static const dark = AppSemanticColors(
    success:         Color(0xFF34D399),
    warning:         Color(0xFFFBBF24),
    danger:          Color(0xFFF87171),
    info:            Color(0xFF60A5FA),
    elevatedSurface: Color(0xFF1E293B),
    borderSubtle:    Color(0xFF334155),
    trackMuted:      Color(0xFF1F2937),
  );
}

/// Raccourci d'accès aux couleurs sémantiques depuis un `BuildContext`.
extension AppSemanticColorsX on ThemeData {
  AppSemanticColors get semantic =>
      extension<AppSemanticColors>() ?? AppSemanticColors.light;
}

class AppTheme {
  /// Construit un ThemeData clair à partir d'une [ThemePalette].
  /// Si `palette` est null, utilise la palette Fortress par défaut (violet).
  static ThemeData light({ThemePalette? palette}) {
    final p = palette ?? kDefaultPalette;
    return _buildLight(p);
  }

  static ThemeData _buildLight(ThemePalette p) => ThemeData(
    useMaterial3: true,
    extensions: const <ThemeExtension<dynamic>>[
      AppSemanticColors.light,
    ],
    colorScheme: ColorScheme.fromSeed(
      seedColor: p.primary,
      primary:   p.primary,
      brightness: Brightness.light,
      // Forcer surface et background blancs — empêche Material3
      // de générer des teintes violettes sur les popups/dialogs
      surface:    Colors.white,
      onSurface:  AppColors.textPrimary,
      surfaceContainerHighest: Colors.white,
      surfaceContainerHigh:    Colors.white,
      surfaceContainer:        Colors.white,
      surfaceContainerLow:     Colors.white,
      surfaceContainerLowest:  Colors.white,
    ),
    scaffoldBackgroundColor: AppColors.background,
    fontFamily: 'SF Pro Display',

    // ── AppBar ─────────────────────────────────────────────────────────
    appBarTheme: const AppBarTheme(
      elevation: 0,
      centerTitle: true,
      backgroundColor: Colors.white,
      foregroundColor: AppColors.textPrimary,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
    ),

    // ── Cards ──────────────────────────────────────────────────────────
    cardTheme: CardThemeData(
      elevation: 0,
      color: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.divider, width: 1),
      ),
      margin: const EdgeInsets.symmetric(vertical: 6),
    ),

    // ── Dialog ─────────────────────────────────────────────────────────
    dialogTheme: DialogThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      titleTextStyle: const TextStyle(
        fontSize: 16, fontWeight: FontWeight.w700,
        color: AppColors.textPrimary,
      ),
      contentTextStyle: const TextStyle(
        fontSize: 13, color: AppColors.textSecondary, height: 1.4,
      ),
    ),

    // ── BottomSheet ────────────────────────────────────────────────────
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: Colors.white,
      modalElevation: 16,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
    ),

    // ── PopupMenu ──────────────────────────────────────────────────────
    popupMenuTheme: PopupMenuThemeData(
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 6,
      shadowColor: Colors.black.withOpacity(0.12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      textStyle: const TextStyle(
        fontSize: 13, color: AppColors.textPrimary,
        fontWeight: FontWeight.w500,
      ),
    ),

    // ── SnackBar ───────────────────────────────────────────────────────
    snackBarTheme: SnackBarThemeData(
      backgroundColor: const Color(0xFF1E293B),
      contentTextStyle: const TextStyle(
        color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500,
      ),
      actionTextColor: p.primaryLight,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      elevation: 4,
    ),

    // ── Tooltip ────────────────────────────────────────────────────────
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(6),
      ),
      textStyle: const TextStyle(color: Colors.white, fontSize: 11),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    ),

    // ── DatePicker ─────────────────────────────────────────────────────
    datePickerTheme: DatePickerThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      headerBackgroundColor: p.primary,
      headerForegroundColor: Colors.white,
      dayForegroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return Colors.white;
        if (states.contains(WidgetState.disabled)) return AppColors.textHint;
        return AppColors.textPrimary;
      }),
      dayBackgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return p.primary;
        return Colors.transparent;
      }),
      todayForegroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return Colors.white;
        return p.primary;
      }),
      todayBackgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return p.primary;
        return Colors.transparent;
      }),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 8,
      shadowColor: Colors.black.withOpacity(0.1),
    ),

    // ── TimePicker ─────────────────────────────────────────────────────
    timePickerTheme: TimePickerThemeData(
      backgroundColor: Colors.white,
      hourMinuteColor: p.primarySurface,
      hourMinuteTextColor: p.primary,
      dialBackgroundColor: p.primarySurface,
      dialHandColor: p.primary,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),

    // ── ListTile ───────────────────────────────────────────────────────
    listTileTheme: const ListTileThemeData(
      titleTextStyle: TextStyle(
        fontSize: 14, fontWeight: FontWeight.w500,
        color: AppColors.textPrimary,
      ),
      subtitleTextStyle: TextStyle(
        fontSize: 12, color: AppColors.textSecondary,
      ),
      iconColor: AppColors.textSecondary,
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    ),

    // ── Drawer ─────────────────────────────────────────────────────────
    drawerTheme: const DrawerThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),

    // ── NavigationBar ──────────────────────────────────────────────────
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.white,
      indicatorColor: p.primarySurface,
      surfaceTintColor: Colors.transparent,
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
              color: p.primary);
        }
        return const TextStyle(fontSize: 11, color: AppColors.textSecondary);
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return IconThemeData(color: p.primary, size: 22);
        }
        return const IconThemeData(color: AppColors.textSecondary, size: 22);
      }),
    ),

    // ── Segmented button ───────────────────────────────────────────────
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return p.primary;
          return Colors.white;
        }),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return Colors.white;
          return AppColors.textSecondary;
        }),
        side: WidgetStateProperty.all(
          const BorderSide(color: AppColors.inputBorder, width: 1),
        ),
        shape: WidgetStateProperty.all(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    ),

    // ── Switch ─────────────────────────────────────────────────────────
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return Colors.white;
        return const Color(0xFFD1D5DB);
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return p.primary;
        return const Color(0xFFE5E7EB);
      }),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),

    // ── Checkbox ───────────────────────────────────────────────────────
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return p.primary;
        return Colors.transparent;
      }),
      checkColor: WidgetStateProperty.all(Colors.white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      side: const BorderSide(color: AppColors.inputBorder, width: 1.5),
    ),

    // ── Divider ────────────────────────────────────────────────────────
    dividerTheme: const DividerThemeData(
      color: AppColors.divider, thickness: 1, space: 24,
    ),

    // ── Inputs ─────────────────────────────────────────────────────────
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.inputFill,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.inputBorder)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.inputBorder)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: p.primary, width: 1.5)),
      errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.error)),
      focusedErrorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.error, width: 1.5)),
      hintStyle: const TextStyle(color: AppColors.textHint, fontSize: 14),
      labelStyle: const TextStyle(color: AppColors.textSecondary),
      prefixIconColor: AppColors.textSecondary,
      suffixIconColor: AppColors.textSecondary,
    ),

    // ── Boutons ────────────────────────────────────────────────────────
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: p.primary,
        foregroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        minimumSize: const Size(double.infinity, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600,
            letterSpacing: 0.3),
      ),
    ),

    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.textPrimary,
        minimumSize: const Size(double.infinity, 52),
        side: const BorderSide(color: AppColors.inputBorder),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      ),
    ),

    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.primary,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      ),
    ),

    // ── Textes ─────────────────────────────────────────────────────────
    textTheme: const TextTheme(
      headlineLarge:  TextStyle(fontSize: 28, fontWeight: FontWeight.bold,
          color: AppColors.textPrimary, height: 1.3),
      headlineMedium: TextStyle(fontSize: 24, fontWeight: FontWeight.bold,
          color: AppColors.textPrimary),
      titleLarge:     TextStyle(fontSize: 18, fontWeight: FontWeight.w600,
          color: AppColors.textPrimary),
      titleMedium:    TextStyle(fontSize: 16, fontWeight: FontWeight.w600,
          color: AppColors.textPrimary),
      bodyLarge:      TextStyle(fontSize: 16, color: AppColors.textPrimary,
          height: 1.5),
      bodyMedium:     TextStyle(fontSize: 14, color: AppColors.textSecondary,
          height: 1.5),
      bodySmall:      TextStyle(fontSize: 12, color: AppColors.textSecondary),
      labelLarge:     TextStyle(fontSize: 14, fontWeight: FontWeight.w500,
          color: AppColors.textPrimary),
    ),
  );

  // ── Thème sombre (minimal) ───────────────────────────────────────────────
  static ThemeData dark({ThemePalette? palette}) {
    final p = palette ?? kDefaultPalette;
    return ThemeData(
      useMaterial3: true,
      extensions: const <ThemeExtension<dynamic>>[
        AppSemanticColors.dark,
      ],
      colorScheme: ColorScheme.fromSeed(
        seedColor: p.primary,
        brightness: Brightness.dark,
        surface:   const Color(0xFF1E293B),
        onSurface: Colors.white,
      ),
    );
  }
}
