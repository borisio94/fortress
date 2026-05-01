import 'package:flutter/material.dart';
import 'app_colors.dart';

/// Styles de texte centralisés.
///
/// Le `theme.textTheme` standard Material (12, 14, 16, 18, 24, 28) ne
/// couvre pas les tailles 9/10/11/13/15/17 omniprésentes dans Fortress.
/// Cette classe les expose sous des noms explicites pour qu'aucune page
/// n'écrive plus `TextStyle(fontSize: 13, color: Color(0xFF6B7280))` en dur.
///
/// **Convention de nommage :** `<usage><taille>[Bold|Secondary|...]`
///   - `usage` : micro / caption / body / label / subtitle / title
///   - `taille` : pixel size en clair (9, 10, 11, 12, 13, 14, 15, 16, 17, 18)
///   - suffixe `Bold` pour FontWeight.w700, `Secondary` pour textSecondary, etc.
///
/// **Exemple :**
/// ```dart
/// Text('label', style: AppTextStyles.caption11)
/// Text('valeur', style: AppTextStyles.body13Bold.copyWith(
///   color: theme.semantic.success,
/// ))
/// ```
class AppTextStyles {
  AppTextStyles._();

  // ─── Tailles micro (9-10) — badges, timestamps, métadonnées ───────────
  static const micro9 = TextStyle(
      fontSize: 9, color: AppColors.textHint);
  static const micro9Bold = TextStyle(
      fontSize: 9, fontWeight: FontWeight.w700, color: AppColors.textHint);
  static const micro10 = TextStyle(
      fontSize: 10, color: AppColors.textHint);
  static const micro10Bold = TextStyle(
      fontSize: 10, fontWeight: FontWeight.w600, color: AppColors.textSecondary);

  // ─── Caption (11) — labels mineurs, légendes ──────────────────────────
  static const caption11 = TextStyle(
      fontSize: 11, color: AppColors.textSecondary);
  static const caption11Bold = TextStyle(
      fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary);
  static const caption11Hint = TextStyle(
      fontSize: 11, color: AppColors.textHint);

  // ─── Body small (12-13) — corps de texte courant ──────────────────────
  static const body12 = TextStyle(
      fontSize: 12, color: AppColors.textPrimary);
  static const body12Secondary = TextStyle(
      fontSize: 12, color: AppColors.textSecondary);
  static const body12Bold = TextStyle(
      fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.textPrimary);
  static const body13 = TextStyle(
      fontSize: 13, color: AppColors.textPrimary, height: 1.5);
  static const body13Secondary = TextStyle(
      fontSize: 13, color: AppColors.textSecondary, height: 1.5);
  static const body13Bold = TextStyle(
      fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary);

  // ─── Label medium (14) — boutons, champs, labels actifs ───────────────
  static const label14 = TextStyle(
      fontSize: 14, color: AppColors.textPrimary);
  static const label14Bold = TextStyle(
      fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary);
  static const label14Secondary = TextStyle(
      fontSize: 14, color: AppColors.textSecondary);

  // ─── Subtitle (15) — sous-titres de cards ─────────────────────────────
  static const subtitle15 = TextStyle(
      fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.textPrimary);

  // ─── Titles (16-18) — en-têtes de sections, modals ────────────────────
  static const title16 = TextStyle(
      fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textPrimary);
  static const title17 = TextStyle(
      fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.textPrimary);
  static const title18 = TextStyle(
      fontSize: 18, fontWeight: FontWeight.w800, color: AppColors.textPrimary);
}

/// Raccourcis d'accès depuis un BuildContext quand on veut les couleurs
/// dynamiques du thème courant (utile pour le mode sombre).
///
/// ```dart
/// Text('hello', style: context.styles.body13Themed)
/// ```
extension AppTextStylesX on BuildContext {
  AppTextStylesContext get styles => AppTextStylesContext(this);
}

/// Variantes context-aware pour textes qui doivent suivre `colorScheme`.
class AppTextStylesContext {
  final BuildContext _ctx;
  const AppTextStylesContext(this._ctx);

  ColorScheme get _cs => Theme.of(_ctx).colorScheme;

  TextStyle get caption11Themed => TextStyle(
      fontSize: 11, color: _cs.onSurface.withOpacity(0.6));
  TextStyle get body12Themed => TextStyle(
      fontSize: 12, color: _cs.onSurface);
  TextStyle get body13Themed => TextStyle(
      fontSize: 13, color: _cs.onSurface, height: 1.5);
  TextStyle get body13SecondaryThemed => TextStyle(
      fontSize: 13, color: _cs.onSurface.withOpacity(0.65), height: 1.5);
  TextStyle get title16Themed => TextStyle(
      fontSize: 16, fontWeight: FontWeight.w700, color: _cs.onSurface);
}
