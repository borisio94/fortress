import 'package:flutter/material.dart';
import 'app_colors.dart';
import 'brand_contrast.dart';
import '../widgets/touch_target.dart';
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
  /// Surface tintée (fond) pour status danger / warning / success.
  /// Couleurs ~50 dans la nomenclature Tailwind (très claires en light,
  /// très sombres en dark) — pensées pour un texte coloré au-dessus.
  final Color dangerSurface;
  final Color warningSurface;
  final Color successSurface;
  /// Couleurs texte LISIBLES posées sur les surfaces tintées correspondantes.
  /// Plus sombres que `danger`/`warning` directs (qui restent destinés aux
  /// icônes / chips colorés sur fond neutre).
  final Color dangerText;
  final Color warningText;
  final Color successText;
  /// Couleurs « brand » dérivées de la palette utilisateur courante.
  /// `brand` = primary de la palette ; `brandSurface` = primary mixé avec
  /// surface (blanc en light, slate sombre en dark) à ~10 % d'opacité ;
  /// `brandText` = primary saturé, suffisamment lisible sur brandSurface.
  /// Construits via [lightForBrand] / [darkForBrand] depuis le palette
  /// builder pour suivre dynamiquement les changements de palette boutique.
  final Color brand;
  final Color brandSurface;
  final Color brandText;
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
    required this.dangerSurface,
    required this.warningSurface,
    required this.successSurface,
    required this.dangerText,
    required this.warningText,
    required this.successText,
    required this.brand,
    required this.brandSurface,
    required this.brandText,
    required this.elevatedSurface,
    required this.borderSubtle,
    required this.trackMuted,
  });

  /// LA COULEUR DE TEXTE d'une couleur d'état : `danger` → `dangerText`,
  /// `warning` → `warningText`, `success` → `successText` ; toute autre
  /// couleur revient telle quelle.
  ///
  /// « Le token suit son fond » : les tokens de BASE sont faits pour une
  /// icône, un trait ou un fond sombre ; posés en texte sur une surface
  /// claire, ils échouent (mesuré sur les 8 palettes, au pire de la carte,
  /// du fond de page et du verre : `warning` 2,01:1, `success` 2,38, `danger`
  /// 3,53). Sur leur propre teinte (10–14 %), `danger` échoue MÊME EN SOMBRE
  /// (4,34). Les variantes `*Text` passent partout : ≥ 6,37 en clair, ≥ 6,32
  /// en sombre, teintes comprises.
  ///
  /// L'aiguillage sert là où la couleur arrive par une variable, un ternaire
  /// ou un paramètre de composant — une même couleur y colore souvent un
  /// texte ET une icône, et seul le texte doit changer.
  ///
  /// `info` n'a PAS de variante texte, et c'est voulu : une information se
  /// dit sans couleur (`textSecondary`, document de design § 16).
  Color textFor(Color base) {
    if (base == danger) return dangerText;
    if (base == warning) return warningText;
    if (base == success) return successText;
    return base;
  }

  @override
  AppSemanticColors copyWith({
    Color? success,
    Color? warning,
    Color? danger,
    Color? info,
    Color? dangerSurface,
    Color? warningSurface,
    Color? successSurface,
    Color? dangerText,
    Color? warningText,
    Color? successText,
    Color? brand,
    Color? brandSurface,
    Color? brandText,
    Color? elevatedSurface,
    Color? borderSubtle,
    Color? trackMuted,
  }) => AppSemanticColors(
    success:         success         ?? this.success,
    warning:         warning         ?? this.warning,
    danger:          danger          ?? this.danger,
    info:            info            ?? this.info,
    dangerSurface:   dangerSurface   ?? this.dangerSurface,
    warningSurface:  warningSurface  ?? this.warningSurface,
    successSurface:  successSurface  ?? this.successSurface,
    dangerText:      dangerText      ?? this.dangerText,
    warningText:     warningText     ?? this.warningText,
    successText:     successText     ?? this.successText,
    brand:           brand           ?? this.brand,
    brandSurface:    brandSurface    ?? this.brandSurface,
    brandText:       brandText       ?? this.brandText,
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
      dangerSurface:   Color.lerp(dangerSurface,   other.dangerSurface,   t)!,
      warningSurface:  Color.lerp(warningSurface,  other.warningSurface,  t)!,
      successSurface:  Color.lerp(successSurface,  other.successSurface,  t)!,
      dangerText:      Color.lerp(dangerText,      other.dangerText,      t)!,
      warningText:     Color.lerp(warningText,     other.warningText,     t)!,
      successText:     Color.lerp(successText,     other.successText,     t)!,
      brand:           Color.lerp(brand,           other.brand,           t)!,
      brandSurface:    Color.lerp(brandSurface,    other.brandSurface,    t)!,
      brandText:       Color.lerp(brandText,       other.brandText,       t)!,
      elevatedSurface: Color.lerp(elevatedSurface, other.elevatedSurface, t)!,
      borderSubtle:    Color.lerp(borderSubtle,    other.borderSubtle,    t)!,
      trackMuted:      Color.lerp(trackMuted,      other.trackMuted,      t)!,
    );
  }

  /// Variante light avec brand par défaut Fortress (violet). Utilisée comme
  /// fallback par l'extension `theme.semantic` quand l'extension n'est pas
  /// trouvée dans le ThemeData (cas hors PosApp — tests, démos).
  static const light = AppSemanticColors(
    success:         Color(0xFF10B981),
    warning:         Color(0xFFF59E0B),
    danger:          Color(0xFFEF4444),
    info:            Color(0xFF3B82F6),
    dangerSurface:   Color(0xFFFCEBEB),
    warningSurface:  Color(0xFFFAEEDA),
    successSurface:  Color(0xFFE7F6EE),
    dangerText:      Color(0xFF991B1B),  // red-800 — lisible sur dangerSurface
    warningText:     Color(0xFF92400E),  // amber-800 — lisible sur warningSurface
    successText:     Color(0xFF065F46),  // emerald-800 — lisible sur successSurface
    brand:           Color(0xFF6C3FC7),  // Fortress violet par défaut
    brandSurface:    Color(0xFFEDE7F8),  // violet-50 dérivé
    brandText:       Color(0xFF5B2FB8),  // violet-700 dérivé
    elevatedSurface: Color(0xFFFFFFFF),
    borderSubtle:    Color(0xFFE5E7EB),
    trackMuted:      Color(0xFFF3F4F6),
  );

  static const dark = AppSemanticColors(
    success:         Color(0xFF34D399),
    warning:         Color(0xFFFBBF24),
    danger:          Color(0xFFF87171),
    info:            Color(0xFF60A5FA),
    dangerSurface:   Color(0xFF3A1818),
    warningSurface:  Color(0xFF3B2911),
    successSurface:  Color(0xFF15321F),
    dangerText:      Color(0xFFFCA5A5),  // red-300 — lisible sur dark dangerSurface
    warningText:     Color(0xFFFCD34D),  // amber-300 — lisible sur dark warningSurface
    successText:     Color(0xFF6EE7B7),  // emerald-300 — lisible sur dark successSurface
    brand:           Color(0xFF8B5CF6),  // violet-500 plus clair pour dark
    brandSurface:    Color(0xFF2A1F4D),  // violet-950 dérivé
    brandText:       Color(0xFFC4B5FD),  // violet-300 — lisible sur dark brandSurface
    elevatedSurface: Color(0xFF1E293B),
    borderSubtle:    Color(0xFF334155),
    trackMuted:      Color(0xFF1F2937),
  );

  /// Dérive une instance light avec `brand` adapté à la palette utilisateur.
  /// Tous les autres tokens (success/warning/danger/etc.) restent universels
  /// — seules les 3 variantes brand suivent la palette boutique custom.
  factory AppSemanticColors.lightForBrand(Color brand) {
    final brandSurface = Color.alphaBlend(
      brand.withValues(alpha: 0.10),
      const Color(0xFFFFFFFF),
    );
    return AppSemanticColors(
      success:         const Color(0xFF10B981),
      warning:         const Color(0xFFF59E0B),
      danger:          const Color(0xFFEF4444),
      info:            const Color(0xFF3B82F6),
      dangerSurface:   const Color(0xFFFCEBEB),
      warningSurface:  const Color(0xFFFAEEDA),
      successSurface:  const Color(0xFFE7F6EE),
      dangerText:      const Color(0xFF991B1B),
      warningText:     const Color(0xFF92400E),
      successText:     const Color(0xFF065F46),
      brand:           brand,
      brandSurface:    brandSurface,
      brandText:       brand, // primary saturé est lisible sur sa surface ~10%
      elevatedSurface: const Color(0xFFFFFFFF),
      borderSubtle:    const Color(0xFFE5E7EB),
      trackMuted:      const Color(0xFFF3F4F6),
    );
  }

  /// Pendant dark de [lightForBrand]. [primary] = la primaire BRUTE de la
  /// palette.
  ///
  /// `brandSurface` = la primaire brute mélangée à ~20 % sur la carte slate.
  /// `brand` et `brandText` = sa variante TEXTE, [BrandContrast.darkBrandText] :
  /// lisible à 4,5:1 sur la carte, le fond ET cette `brandSurface`. Avant le
  /// 25/09/2026 ils valaient la primaire brute — 1,00:1 sur Midnight, 2,21:1
  /// sur Violet, et le couple `brandText`/`brandSurface` échouait sur les
  /// huit palettes.
  factory AppSemanticColors.darkForBrand(Color primary) {
    final brandSurface =
        BrandContrast.darkTint(primary, BrandContrast.kBrandSurfaceAlpha);
    final brand = BrandContrast.darkBrandText(primary);
    return AppSemanticColors(
      success:         const Color(0xFF34D399),
      warning:         const Color(0xFFFBBF24),
      danger:          const Color(0xFFF87171),
      info:            const Color(0xFF60A5FA),
      dangerSurface:   const Color(0xFF3A1818),
      warningSurface:  const Color(0xFF3B2911),
      successSurface:  const Color(0xFF15321F),
      dangerText:      const Color(0xFFFCA5A5),
      warningText:     const Color(0xFFFCD34D),
      successText:     const Color(0xFF6EE7B7),
      brand:           brand,
      brandSurface:    brandSurface,
      brandText:       brand, // variante texte dérivée (voir ci-dessus)
      elevatedSurface: const Color(0xFF1E293B),
      borderSubtle:    const Color(0xFF334155),
      trackMuted:      const Color(0xFF1F2937),
    );
  }
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
    // Ripple classique (cercle qui s'étend) sur TOUS les widgets à encre :
    // boutons, IconButton, ListTile, InkWell… — bien plus visible que
    // l'InkSparkle M3 par défaut, idéal pour les tutoriels en capture vidéo.
    splashFactory: InkRipple.splashFactory,
    // Brand dynamique : suit la palette utilisateur. Les autres tokens
    // (success/warning/danger/etc.) restent universels via la factory.
    extensions: <ThemeExtension<dynamic>>[
      AppSemanticColors.lightForBrand(p.primary),
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
    fontFamily: 'Inter',

    // ── AppBar ─────────────────────────────────────────────────────────
    appBarTheme: AppBarTheme(
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
        side: BorderSide(color: AppColors.divider, width: 1),
      ),
      margin: const EdgeInsets.symmetric(vertical: 6),
    ),

    // ── Dialog ─────────────────────────────────────────────────────────
    dialogTheme: DialogThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      titleTextStyle: TextStyle(
        fontSize: 16, fontWeight: FontWeight.w700,
        color: AppColors.textPrimary,
      ),
      contentTextStyle: TextStyle(
        fontSize: 13, color: AppColors.textSecondary, height: 1.5,
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
      shadowColor: Colors.black.withValues(alpha:0.12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      textStyle: TextStyle(
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
      shadowColor: Colors.black.withValues(alpha:0.1),
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
    listTileTheme: ListTileThemeData(
      titleTextStyle: const TextStyle(
        fontSize: 14, fontWeight: FontWeight.w600, height: 1.4,
      ).copyWith(color: AppColors.textPrimary),
      subtitleTextStyle: const TextStyle(
        fontSize: 12, height: 1.45,
      ).copyWith(color: AppColors.textSecondary),
      iconColor: AppColors.textSecondary,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
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
        return TextStyle(fontSize: 11, color: AppColors.textSecondary);
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return IconThemeData(color: p.primary, size: 22);
        }
        return IconThemeData(color: AppColors.textSecondary, size: 22);
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
          BorderSide(color: AppColors.inputBorder, width: 1),
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
      side: BorderSide(color: AppColors.inputBorder, width: 1.5),
    ),

    // ── Divider ────────────────────────────────────────────────────────
    dividerTheme: DividerThemeData(
      color: AppColors.divider, thickness: 1, space: 24,
    ),

    // ── Inputs ─────────────────────────────────────────────────────────
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.inputFill,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.inputBorder)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.inputBorder)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: p.primary, width: 2)),
      errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.error)),
      focusedErrorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.error, width: 2)),
      hintStyle: TextStyle(color: AppColors.textHint, fontSize: 14),
      labelStyle: TextStyle(color: AppColors.textSecondary),
      prefixIconColor: AppColors.textSecondary,
      suffixIconColor: AppColors.textSecondary,
    ),

    // ── Boutons ────────────────────────────────────────────────────────
    // Boutons : dimensionnés au CONTENU + padding compact (H10/V3) — demande
    // utilisateur. `minimumSize: Size.zero` + `shrinkWrap` retirent le plancher
    // pleine-largeur/52px. Les boutons VOULUS pleine largeur (connexion, footers
    // de formulaire…) le restent car ils sont enveloppés dans un SizedBox /
    // fixent leur propre style, qui prime sur le thème.
    //
    // `tapTargetSize` ADAPTATIF (lot 2, 25/09/2026) : au DOIGT, `padded` donne
    // à chaque bouton une zone de 48 px sans changer son dessin ; à la souris,
    // `shrinkWrap` garde la densité de bureau. Cf. `core/widgets/touch_target.dart`.
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: p.primary,
        foregroundColor: Colors.white,
        // Ripple blanc visible sur fond primary (capture tuto).
        overlayColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        minimumSize: Size.zero,
        tapTargetSize: adaptiveTapTargetSize,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600,
            letterSpacing: 0.3),
      ),
    ),

    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.textPrimary,
        overlayColor: p.primary,
        minimumSize: Size.zero,
        tapTargetSize: adaptiveTapTargetSize,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        side: BorderSide(color: AppColors.inputBorder),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      ),
    ),

    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.primary,
        overlayColor: p.primary,
        minimumSize: Size.zero,
        tapTargetSize: adaptiveTapTargetSize,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      ),
    ),

    // FilledButton (sheets, dialogues) — ripple blanc sur fond plein.
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        overlayColor: Colors.white,
        minimumSize: Size.zero,
        tapTargetSize: adaptiveTapTargetSize,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        // Coins arrondis modérés (cohérent elevated/outlined) au lieu de la
        // forme « pilule » (StadiumBorder) par défaut de M3 pour FilledButton.
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),

    // IconButton (app bars, toolbars) — ripple primary visible.
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(overlayColor: p.primary),
    ),

    // ── Textes ─────────────────────────────────────────────────────────
    // Slots Material calés sur les 7 échelons de AppTextStyles. Ainsi tout
    // `Text()` ou widget Material non stylé explicitement tombe déjà sur
    // l'échelle (cohérence par défaut, avant même migration des pages).
    //   bodyLarge = échelon `label` (14) → défaut du texte SAISI M3.
    //   bodyMedium = échelon `body` (13) → défaut de Text().
    textTheme: TextTheme(
      headlineLarge:  const TextStyle(fontSize: 24, fontWeight: FontWeight.w800,
          height: 1.2).copyWith(color: AppColors.textPrimary),     // display
      headlineMedium: TextStyle(fontSize: 24, fontWeight: FontWeight.w800,
          color: AppColors.textPrimary, height: 1.2),     // display
      headlineSmall:  TextStyle(fontSize: 18, fontWeight: FontWeight.w700,
          color: AppColors.textPrimary, height: 1.3),     // title
      titleLarge:     TextStyle(fontSize: 18, fontWeight: FontWeight.w700,
          color: AppColors.textPrimary, height: 1.3),     // title
      titleMedium:    TextStyle(fontSize: 16, fontWeight: FontWeight.w600,
          color: AppColors.textPrimary, height: 1.35),    // subtitle
      titleSmall:     TextStyle(fontSize: 14, fontWeight: FontWeight.w600,
          color: AppColors.textPrimary, height: 1.4),     // label
      bodyLarge:      TextStyle(fontSize: 14, color: AppColors.textPrimary,
          height: 1.3),                                    // input/label
      bodyMedium:     TextStyle(fontSize: 13, color: AppColors.textPrimary,
          height: 1.5),                                    // body (défaut)
      bodySmall:      TextStyle(fontSize: 12, color: AppColors.textSecondary,
          height: 1.45),                                   // bodySm
      labelLarge:     TextStyle(fontSize: 14, fontWeight: FontWeight.w600,
          color: AppColors.textPrimary, height: 1.4),      // label
      labelMedium:    TextStyle(fontSize: 11, fontWeight: FontWeight.w500,
          color: AppColors.textSecondary, height: 1.35),   // caption
      labelSmall:     TextStyle(fontSize: 10, color: AppColors.textHint,
          height: 1.3),                                    // micro
    ),
  );

  // ── Thème sombre ─────────────────────────────────────────────────────────
  // Palette Slate (Tailwind) cohérente avec `AppSemanticColors.darkForBrand`
  // (elevatedSurface 0xFF1E293B, borderSubtle 0xFF334155). Ces constantes
  // sont les pendants sombres des `AppColors.*` fixes utilisées par le
  // light theme — on les définit ici plutôt que dans AppColors pour ne pas
  // exposer de tokens « dark » statiques qui seraient lus hors thème.
  static const Color _dScaffold = Color(0xFF0F172A); // slate 900
  static const Color _dSurface  = Color(0xFF1E293B); // slate 800
  static const Color _dBorder   = Color(0xFF334155); // slate 700
  static const Color _dInputFill = Color(0xFF334155);
  static const Color _dTextPrimary   = Color(0xFFF1F5F9); // slate 100
  static const Color _dTextSecondary = Color(0xFF94A3B8); // slate 400
  static const Color _dTextHint      = Color(0xFF64748B); // slate 500

  static ThemeData dark({ThemePalette? palette}) {
    final p = palette ?? kDefaultPalette;
    // LA PRIMAIRE EN SOMBRE A DEUX VALEURS, DÉRIVÉES (cf. `brand_contrast.dart`) :
    // une couleur ne peut pas être à la fois lisible SUR la carte sombre et
    // porter du blanc. `onDark` pour tout ce qui se LIT (texte, icône, trait,
    // indicateur) ; `fill` pour le fond des boutons pleins, sous du blanc.
    // Avant le 25/09/2026, les deux valaient `primaryLight` : 1,93:1 sur la
    // carte pour Midnight, et du blanc à moins de 2,7:1 sur six palettes.
    final onDark = BrandContrast.darkText(p.primary);
    final fill   = BrandContrast.fillUnderWhite(p.primaryLight);
    // L'action d'un snack se lit sur SON fond (`#334155`, plus clair que la
    // carte) : même règle, autre surface.
    final snackAction = BrandContrast.readableOn(p.primary, const [_dInputFill]);
    return ThemeData(
      useMaterial3: true,
      fontFamily: 'Inter',
      // Ripple classique visible sur tous les widgets à encre (cf. light).
      splashFactory: InkRipple.splashFactory,
      extensions: <ThemeExtension<dynamic>>[
        AppSemanticColors.darkForBrand(p.primary),
      ],
      colorScheme: ColorScheme.fromSeed(
        seedColor: p.primary,
        brightness: Brightness.dark,
        // Variante TEXTE dérivée : 4,5:1 sur la carte et le fond pour toute
        // palette, y compris celles issues d'un logo. `primaryLight` ne
        // suffisait pas (Midnight 1,93:1, Indigo 3,27:1, Violet 3,45:1).
        primary:   onDark,
        // Sur une primaire claire, le contenu est SOMBRE (modèle Material 3
        // en sombre) : le fond du thème, ≥ 4,5:1 par construction.
        onPrimary: _dScaffold,
        surface:   _dSurface,
        onSurface: _dTextPrimary,
        // Force les conteneurs M3 sur la surface slate plutôt que les
        // teintes violettes auto-générées (miroir du light theme).
        surfaceContainerHighest: _dSurface,
        surfaceContainerHigh:    _dSurface,
        surfaceContainer:        _dSurface,
        surfaceContainerLow:     _dSurface,
        surfaceContainerLowest:  _dScaffold,
      ),
      scaffoldBackgroundColor: _dScaffold,

      appBarTheme: const AppBarTheme(
        elevation: 0,
        centerTitle: true,
        backgroundColor: _dSurface,
        foregroundColor: _dTextPrimary,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
      ),

      cardTheme: CardThemeData(
        elevation: 0,
        color: _dSurface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: _dBorder, width: 1),
        ),
        margin: const EdgeInsets.symmetric(vertical: 6),
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: _dSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        titleTextStyle: const TextStyle(
          fontSize: 16, fontWeight: FontWeight.w700, color: _dTextPrimary,
        ),
        contentTextStyle: const TextStyle(
          fontSize: 13, color: _dTextSecondary, height: 1.5,
        ),
      ),

      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: _dSurface,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: _dSurface,
        modalElevation: 16,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
      ),

      popupMenuTheme: PopupMenuThemeData(
        color: _dSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 6,
        shadowColor: Colors.black.withValues(alpha: 0.4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(
          fontSize: 13, color: _dTextPrimary, fontWeight: FontWeight.w500,
        ),
      ),

      snackBarTheme: SnackBarThemeData(
        backgroundColor: const Color(0xFF334155),
        contentTextStyle: const TextStyle(
          color: _dTextPrimary, fontSize: 13, fontWeight: FontWeight.w500,
        ),
        actionTextColor: snackAction,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        elevation: 4,
      ),

      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: const Color(0xFF475569),
          borderRadius: BorderRadius.circular(6),
        ),
        textStyle: const TextStyle(color: _dTextPrimary, fontSize: 11),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      ),

      dividerTheme: const DividerThemeData(
        color: _dBorder, thickness: 1, space: 24,
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: _dInputFill,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: _dBorder)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: _dBorder)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: onDark, width: 2)),
        errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppColors.error)),
        focusedErrorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppColors.error, width: 2)),
        hintStyle: const TextStyle(color: _dTextHint, fontSize: 14),
        labelStyle: const TextStyle(color: _dTextSecondary),
        prefixIconColor: _dTextSecondary,
        suffixIconColor: _dTextSecondary,
      ),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          // Fond dérivé sous le blanc (≥ 4,5:1) — cf. `fill` plus haut.
          backgroundColor: fill,
          foregroundColor: Colors.white,
          overlayColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          minimumSize: Size.zero,
          tapTargetSize: adaptiveTapTargetSize,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600,
              letterSpacing: 0.3),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: _dTextPrimary,
          overlayColor: p.primaryLight,
          minimumSize: Size.zero,
          tapTargetSize: adaptiveTapTargetSize,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          side: const BorderSide(color: _dBorder),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: onDark,
          overlayColor: p.primaryLight,
          minimumSize: Size.zero,
          tapTargetSize: adaptiveTapTargetSize,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          // Même fond que l'ElevatedButton : sans lui, le FilledButton
          // prendrait la primaire du schéma — désormais CLAIRE en sombre.
          backgroundColor: fill,
          foregroundColor: Colors.white,
          overlayColor: Colors.white,
          minimumSize: Size.zero,
          tapTargetSize: adaptiveTapTargetSize,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          // Coins arrondis modérés au lieu de la « pilule » M3 par défaut.
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),

      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(overlayColor: p.primaryLight),
      ),

      listTileTheme: const ListTileThemeData(
        titleTextStyle: TextStyle(
          fontSize: 14, fontWeight: FontWeight.w600, height: 1.4,
          color: _dTextPrimary,
        ),
        subtitleTextStyle: TextStyle(
          fontSize: 12, height: 1.45, color: _dTextSecondary,
        ),
        iconColor: _dTextSecondary,
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),

      drawerTheme: const DrawerThemeData(
        backgroundColor: _dSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),

      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: _dSurface,
        indicatorColor: p.primaryLight.withValues(alpha: 0.18),
        surfaceTintColor: Colors.transparent,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                color: onDark);
          }
          return const TextStyle(fontSize: 11, color: _dTextSecondary);
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return IconThemeData(color: onDark, size: 22);
          }
          return const IconThemeData(color: _dTextSecondary, size: 22);
        }),
      ),

      textTheme: const TextTheme(
        headlineLarge:  TextStyle(fontSize: 24, fontWeight: FontWeight.w800,
            color: _dTextPrimary, height: 1.2),
        headlineMedium: TextStyle(fontSize: 24, fontWeight: FontWeight.w800,
            color: _dTextPrimary, height: 1.2),
        headlineSmall:  TextStyle(fontSize: 18, fontWeight: FontWeight.w700,
            color: _dTextPrimary, height: 1.3),
        titleLarge:     TextStyle(fontSize: 18, fontWeight: FontWeight.w700,
            color: _dTextPrimary, height: 1.3),
        titleMedium:    TextStyle(fontSize: 16, fontWeight: FontWeight.w600,
            color: _dTextPrimary, height: 1.35),
        titleSmall:     TextStyle(fontSize: 14, fontWeight: FontWeight.w600,
            color: _dTextPrimary, height: 1.4),
        bodyLarge:      TextStyle(fontSize: 14, color: _dTextPrimary,
            height: 1.3),
        bodyMedium:     TextStyle(fontSize: 13, color: _dTextPrimary,
            height: 1.5),
        bodySmall:      TextStyle(fontSize: 12, color: _dTextSecondary,
            height: 1.45),
        labelLarge:     TextStyle(fontSize: 14, fontWeight: FontWeight.w600,
            color: _dTextPrimary, height: 1.4),
        labelMedium:    TextStyle(fontSize: 11, fontWeight: FontWeight.w500,
            color: _dTextSecondary, height: 1.35),
        labelSmall:     TextStyle(fontSize: 10, color: _dTextHint,
            height: 1.3),
      ),
    );
  }
}
