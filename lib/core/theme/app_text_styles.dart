import 'package:flutter/material.dart';
import 'app_colors.dart';

/// ════════════════════════════════════════════════════════════════════════
/// ÉCHELLE TYPOGRAPHIQUE FORTRESS — une seule source de vérité.
///
/// Police : `Inter` (embarquée, cf. pubspec.yaml) → rendu strictement
/// identique sur web / Android / iOS.
///
/// L'app ne doit JAMAIS écrire `TextStyle(fontSize: 13, color: …)` en dur.
/// On choisit l'échelon le plus proche du besoin parmi les 7 ci-dessous,
/// puis on ajuste seulement la couleur via `.copyWith(color: …)`.
///
/// ── LES 7 ÉCHELONS (du plus petit au plus grand) ───────────────────────
///
///  | Échelon      | px | Poids | Usage                                    |
///  |--------------|----|-------|------------------------------------------|
///  | `micro`      | 10 | 400   | badges, horodatage, métadonnées          |
///  | `caption`    | 11 | 500   | légendes, labels de champ, helper text   |
///  | `bodySm`     | 12 | 400   | texte secondaire dense (listes serrées)  |
///  | `body`       | 13 | 400   | CORPS PAR DÉFAUT (paragraphes, valeurs)  |
///  | `label`      | 14 | 600   | saisie, boutons, items de liste, onglets |
///  | `subtitle`   | 16 | 600   | sous-titres, titres de card / dialogue   |
///  | `title`      | 18 | 700   | titres de page / section / AppBar        |
///
///  + échelon spécial chiffres : `display` (24, w800) pour les gros KPI.
///
/// Chaque échelon a 3 variantes prêtes à l'emploi :
///   `Xxx`         → couleur primaire (texte principal)
///   `XxxSecondary`→ couleur secondaire (gris moyen)
///   `XxxBold`     → poids renforcé (w700)
///
/// ── COMPATIBILITÉ ──────────────────────────────────────────────────────
/// Les anciens noms (`micro9`, `body13`, `subtitle15`, `title16`, …) sont
/// conservés comme alias pour ne rien casser, mais sont @Deprecated : tout
/// nouveau code et toute migration doit utiliser les 7 échelons ci-dessus.
/// ════════════════════════════════════════════════════════════════════════
class AppTextStyles {
  AppTextStyles._();

  // ════════════════════════════════════════════════════════════════════
  //  ÉCHELLE CANONIQUE — à utiliser partout
  //
  //  ⚠ COULEUR (mode sombre) : les échelons de texte PRINCIPAL (body,
  //  label, subtitle, title, display, input…) n'ont VOLONTAIREMENT PAS
  //  de `color`. Ils héritent donc de `textTheme.bodyMedium` du thème
  //  courant (sombre en clair, clair en sombre) — c'est ce qui rend le
  //  texte lisible en mode sombre sans toucher chaque `Text()`.
  //  → Ne PAS réintroduire `color: AppColors.textPrimary` ici.
  //  Les variantes `*Secondary` / `*Hint` gardent une couleur grise
  //  (hiérarchie visuelle) qui reste lisible dans les deux modes.
  // ════════════════════════════════════════════════════════════════════

  // ── 1. micro (10) ────────────────────────────────────────────────────
  // GETTERS (non-const) : la couleur secondary/hint suit le mode clair/sombre.
  static TextStyle get micro => const TextStyle(fontSize: 10, height: 1.3)
      .copyWith(color: AppColors.textHint);
  static TextStyle get microSecondary =>
      const TextStyle(fontSize: 10, height: 1.3)
          .copyWith(color: AppColors.textSecondary);
  static TextStyle get microBold => const TextStyle(
          fontSize: 10, height: 1.3, fontWeight: FontWeight.w700)
      .copyWith(color: AppColors.textSecondary);

  // ── 2. caption (11) ──────────────────────────────────────────────────
  static TextStyle get caption => const TextStyle(
          fontSize: 11, height: 1.35, fontWeight: FontWeight.w500)
      .copyWith(color: AppColors.textSecondary);
  static TextStyle get captionHint =>
      const TextStyle(fontSize: 11, height: 1.35)
          .copyWith(color: AppColors.textHint);
  static TextStyle get captionBold => const TextStyle(
          fontSize: 11, height: 1.35, fontWeight: FontWeight.w700)
      .copyWith(color: AppColors.textSecondary);

  // ── 3. bodySm (12) ───────────────────────────────────────────────────
  static const bodySm = TextStyle(
      fontSize: 12, height: 1.45);
  static TextStyle get bodySmSecondary =>
      const TextStyle(fontSize: 12, height: 1.45)
          .copyWith(color: AppColors.textSecondary);
  static const bodySmBold = TextStyle(
      fontSize: 12, height: 1.45,
      fontWeight: FontWeight.w700);

  // ── 4. body (13) — CORPS PAR DÉFAUT ──────────────────────────────────
  static const body = TextStyle(
      fontSize: 13, height: 1.5);
  static TextStyle get bodySecondary =>
      const TextStyle(fontSize: 13, height: 1.5)
          .copyWith(color: AppColors.textSecondary);
  static const bodyBold = TextStyle(
      fontSize: 13, height: 1.5,
      fontWeight: FontWeight.w700);

  // ── 5. label (14) — saisie / boutons / listes ────────────────────────
  static const label = TextStyle(
      fontSize: 14, height: 1.4,
      fontWeight: FontWeight.w600);
  static const labelRegular = TextStyle(
      fontSize: 14, height: 1.4);
  static TextStyle get labelSecondary =>
      const TextStyle(fontSize: 14, height: 1.4)
          .copyWith(color: AppColors.textSecondary);

  /// Texte SAISI dans un champ (TextField / TextFormField). Échelon `label`
  /// sans gras. UNIQUE référence pour la taille de saisie de toute l'app
  /// → plus aucun champ « trop grand / trop petit ».
  static const input = TextStyle(
      fontSize: 14, height: 1.3);

  /// Placeholder / hint d'un champ — même taille que [input], couleur hint.
  static TextStyle get inputHint =>
      const TextStyle(fontSize: 14, height: 1.3)
          .copyWith(color: AppColors.textHint);

  // ── 6. subtitle (16) — sous-titres / titres de card / dialogue ───────
  static const subtitle = TextStyle(
      fontSize: 16, height: 1.35,
      fontWeight: FontWeight.w600);
  static const subtitleBold = TextStyle(
      fontSize: 16, height: 1.35,
      fontWeight: FontWeight.w700);

  // ── 7. title (18) — titres de page / section ─────────────────────────
  static const title = TextStyle(
      fontSize: 18, height: 1.3,
      fontWeight: FontWeight.w700);

  // ── + display (24) — gros chiffres KPI uniquement ────────────────────
  static const display = TextStyle(
      fontSize: 24, height: 1.2,
      fontWeight: FontWeight.w800);

  // ════════════════════════════════════════════════════════════════════
  //  ALIAS HÉRITÉS — @Deprecated, conservés pour compat (ne pas réutiliser)
  //  Chaque alias est CALÉ sur l'échelon canonique le plus proche pour que
  //  les écrans non encore migrés s'alignent automatiquement.
  // ════════════════════════════════════════════════════════════════════

  // Alias vers des échelons devenus getters (couleur adaptative) → getters.
  @Deprecated('Utiliser AppTextStyles.micro')
  static TextStyle get micro9 => micro;
  @Deprecated('Utiliser AppTextStyles.microBold')
  static TextStyle get micro9Bold => microBold;
  @Deprecated('Utiliser AppTextStyles.micro')
  static TextStyle get micro10 => micro;
  @Deprecated('Utiliser AppTextStyles.microBold')
  static TextStyle get micro10Bold => microBold;

  @Deprecated('Utiliser AppTextStyles.caption')
  static TextStyle get caption11 => caption;
  @Deprecated('Utiliser AppTextStyles.captionBold')
  static TextStyle get caption11Bold => captionBold;
  @Deprecated('Utiliser AppTextStyles.captionHint')
  static TextStyle get caption11Hint => captionHint;

  @Deprecated('Utiliser AppTextStyles.bodySm')
  static const body12 = bodySm;
  @Deprecated('Utiliser AppTextStyles.bodySmSecondary')
  static TextStyle get body12Secondary => bodySmSecondary;
  @Deprecated('Utiliser AppTextStyles.bodySmBold')
  static const body12Bold = bodySmBold;

  @Deprecated('Utiliser AppTextStyles.body')
  static const body13 = body;
  @Deprecated('Utiliser AppTextStyles.bodySecondary')
  static TextStyle get body13Secondary => bodySecondary;
  @Deprecated('Utiliser AppTextStyles.bodyBold')
  static const body13Bold = bodyBold;

  @Deprecated('Utiliser AppTextStyles.labelRegular')
  static const label14 = labelRegular;
  @Deprecated('Utiliser AppTextStyles.label')
  static const label14Bold = label;
  @Deprecated('Utiliser AppTextStyles.labelSecondary')
  static TextStyle get label14Secondary => labelSecondary;

  @Deprecated('Utiliser AppTextStyles.subtitle')
  static const subtitle15 = subtitle;

  @Deprecated('Utiliser AppTextStyles.subtitle')
  static const title16 = subtitle;
  @Deprecated('Utiliser AppTextStyles.title')
  static const title17 = title;
  @Deprecated('Utiliser AppTextStyles.title')
  static const title18 = title;
}

/// Raccourcis context-aware : mêmes échelons mais couleurs tirées du
/// `colorScheme` courant (indispensable pour le mode sombre).
///
/// ```dart
/// Text('hello', style: context.styles.bodyThemed)
/// ```
extension AppTextStylesX on BuildContext {
  AppTextStylesContext get styles => AppTextStylesContext(this);
}

class AppTextStylesContext {
  final BuildContext _ctx;
  const AppTextStylesContext(this._ctx);

  ColorScheme get _cs => Theme.of(_ctx).colorScheme;

  TextStyle get captionThemed => TextStyle(
      fontSize: 11, height: 1.35, fontWeight: FontWeight.w500,
      color: _cs.onSurface.withValues(alpha: 0.6));
  TextStyle get bodySmThemed => TextStyle(
      fontSize: 12, height: 1.45, color: _cs.onSurface);
  TextStyle get bodyThemed => TextStyle(
      fontSize: 13, height: 1.5, color: _cs.onSurface);
  TextStyle get bodySecondaryThemed => TextStyle(
      fontSize: 13, height: 1.5,
      color: _cs.onSurface.withValues(alpha: 0.65));
  TextStyle get subtitleThemed => TextStyle(
      fontSize: 16, height: 1.35, fontWeight: FontWeight.w600,
      color: _cs.onSurface);
  TextStyle get titleThemed => TextStyle(
      fontSize: 18, height: 1.3, fontWeight: FontWeight.w700,
      color: _cs.onSurface);

  // ── Alias hérités context-aware ─────────────────────────────────────
  @Deprecated('Utiliser captionThemed')
  TextStyle get caption11Themed => captionThemed;
  @Deprecated('Utiliser bodySmThemed')
  TextStyle get body12Themed => bodySmThemed;
  @Deprecated('Utiliser bodyThemed')
  TextStyle get body13Themed => bodyThemed;
  @Deprecated('Utiliser bodySecondaryThemed')
  TextStyle get body13SecondaryThemed => bodySecondaryThemed;
  @Deprecated('Utiliser subtitleThemed')
  TextStyle get title16Themed => subtitleThemed;
}
