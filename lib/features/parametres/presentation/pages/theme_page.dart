import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/logo_theme_builder.dart';
import '../../../../core/theme/theme_palette.dart';
import '../../../../core/theme/theme_mode_provider.dart';
import '../../../../core/widgets/touch_target.dart';
import '../../../../shared/widgets/app_scaffold.dart';

// ═════════════════════════════════════════════════════════════════════════════
// PAGE APPARENCE — refonte du 25/09/2026, pour LES DEUX SECTEURS.
//
// La palette et le mode sont des réglages de l'APPAREIL (SharedPreferences,
// Hive) : un serveur et un vendeur sur le même téléphone voient la même chose.
// La page n'a rien de propre à un secteur, elle n'a donc pas de branche.
//
// PARTI : en-tête compté, sélecteur segmenté, palettes en cartes compactes
// dont les pavés montrent ce que la palette PRODUIT (voir `themeSwatches`).
//
// RETIRÉ, et pourquoi :
//   • le bandeau « Thème actif » en dégradé — il redisait la coche de la
//     palette et le sous-titre de l'en-tête ;
//   • les trois cartes de mode de 80 px — un choix parmi trois, pas trois
//     actions : un segmenté ;
//   • le réglage « Tableau de bord dans le panier vide » — il ne commandait
//     RIEN : `EmptyCartDashboard` n'a jamais été monté par aucun écran depuis
//     sa création (`25a2334`, 20/05/2026). Le booléen était écrit, jamais lu.
//     Le widget reste en place, inscrit au backlog comme code mort.
//
// ⚠ NON TRANCHÉ, volontairement absent : une OMBRE sur les cartes en clair
// (aucun token d'ombre n'existe) et un FOND de page teinté vers la primaire
// (`primarySurface` est d'intensité trop inégale — Amber `#FEF3C7`). La
// séparation passe par la bordure `borderSubtle`, dans les deux modes.
// ═════════════════════════════════════════════════════════════════════════════

class ThemePage extends ConsumerWidget {
  final String? shopId;
  const ThemePage({super.key, this.shopId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isFr = Localizations.localeOf(context).languageCode == 'fr';
    final current = ref.watch(themePaletteProvider);
    final mode = ref.watch(themeModeProvider);
    final brightness = Theme.of(context).brightness;
    final logo = ThemePaletteNotifier.cachedLogoPalette();

    void select(ThemePalette p) {
      HapticFeedback.selectionClick();
      ref.read(themePaletteProvider.notifier).setPalette(p);
    }

    return AppScaffold(
      shopId: shopId ?? '',
      title: context.l10n.paramTheme,
      isRootPage: false,
      body: LayoutBuilder(
        builder: (context, constraints) {
          // PLANCHER DE TUILE, pas de seuil en pixels : ~150 dp par carte,
          // deux colonnes au moins, quatre au plus — la formule du Plan de
          // salle. Deux sur téléphone, quatre sur ordinateur.
          final cols = ((constraints.maxWidth - 32) / 150).floor().clamp(2, 4);
          final tiles = <Widget>[
            if (logo != null)
              _PaletteTile(
                palette: logo,
                label: isFr ? 'Votre logo' : 'Your logo',
                selected: current.id == LogoThemeBuilder.generatedId,
                onTap: () => select(logo),
              ),
            for (final p in kAllPalettes)
              _PaletteTile(
                palette: p,
                label: p.label(isFr),
                selected: current.id == p.id,
                onTap: () => select(p),
              ),
          ];

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              // ── En-tête : même grammaire que les écrans épurés ──────────
              Text(isFr ? 'Apparence' : 'Appearance',
                  style: AppTextStyles.label
                      .copyWith(color: Theme.of(context).colorScheme.onSurface)),
              const SizedBox(height: 2),
              Text(
                  appearanceSubtitle(
                    paletteLabel: current.id == LogoThemeBuilder.generatedId
                        ? (isFr ? 'Votre logo' : 'Your logo')
                        : current.label(isFr),
                    mode: mode,
                    resolved: brightness,
                    isFr: isFr,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.caption),
              const SizedBox(height: 20),

              _SectionTitle(isFr ? 'Mode' : 'Mode'),
              _ModeSegmented(mode: mode, isFr: isFr),
              const SizedBox(height: 24),

              _SectionTitle(isFr ? 'Couleur' : 'Colour'),
              GridView(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: cols,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  // HAUTEUR FIXE (~90 px), pas un ratio : l'ancienne carte
                  // faisait ~350 px, six palettes tenaient sur trois écrans.
                  mainAxisExtent: 90,
                ),
                children: tiles,
              ),
            ],
          );
        },
      ),
    );
  }
}

// ─── Ce que la page AFFICHE, calculé hors du widget (testé) ──────────────────

/// « Indigo · mode clair ». En mode système, le mode RÉSOLU entre parenthèses
/// — « système » seul ne dirait pas ce que l'utilisateur voit.
@visibleForTesting
String appearanceSubtitle({
  required String paletteLabel,
  required ThemeMode mode,
  required Brightness resolved,
  required bool isFr,
}) {
  final dark = resolved == Brightness.dark;
  final resolvedWord = isFr ? (dark ? 'sombre' : 'clair') : (dark ? 'dark' : 'light');
  final modeText = switch (mode) {
    ThemeMode.light => isFr ? 'mode clair' : 'light mode',
    ThemeMode.dark => isFr ? 'mode sombre' : 'dark mode',
    ThemeMode.system =>
      isFr ? 'mode système ($resolvedWord)' : 'system mode ($resolvedWord)',
  };
  return '$paletteLabel · $modeText';
}

/// LES TROIS PAVÉS D'UNE PALETTE : ce qu'elle PRODUIT dans le mode courant.
///
/// Lus dans le thème RÉEL (`AppTheme.light` / `AppTheme.dark`) — pas dans une
/// seconde table de couleurs. La vignette ne peut donc pas mentir sur ce que
/// la palette donnera, et suivra d'elle-même le jour où les valeurs changeront
/// (le lot 1 n'a dérivé que le SOMBRE : en clair, les pavés 1 et 2 montrent
/// aujourd'hui la primaire brute — sous 4,5:1 sur blanc pour Ocean, Emerald,
/// Sunset, Rose et Amber —, parce que c'est ce que l'app affiche).
///
///   1. `colorScheme.primary` — texte, traits, indicateurs ;
///   2. le fond de l'`ElevatedButton` — les boutons pleins ;
///   3. `semantic.brandSurface` — la surface teintée de marque.
@visibleForTesting
({Color text, Color fill, Color surface}) themeSwatches(
    ThemePalette palette, Brightness brightness) {
  final key = '${palette.id}:${palette.primary.toARGB32()}:${brightness.name}';
  return _swatchCache.putIfAbsent(key, () {
    final t = brightness == Brightness.dark
        ? AppTheme.dark(palette: palette)
        : AppTheme.light(palette: palette);
    return (
      text: t.colorScheme.primary,
      fill: t.elevatedButtonTheme.style!.backgroundColor!
          .resolve(<WidgetState>{})!,
      surface: t.semantic.brandSurface,
    );
  });
}

/// Un `ThemeData` par palette et par mode, construit une fois : les huit
/// cartes se reconstruisent à chaque changement de palette.
final _swatchCache = <String, ({Color text, Color fill, Color surface})>{};

// ─── Widgets ─────────────────────────────────────────────────────────────────

/// Titre de section en capitales espacées (échelon `micro`, cf. document de
/// design § 5).
class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 2, bottom: 8),
        child: Text(text.toUpperCase(),
            style: AppTextStyles.microBold.copyWith(letterSpacing: 0.8)),
      );
}

/// SÉLECTEUR SEGMENTÉ Clair / Sombre / Système — un choix parmi trois.
///
/// Borné à ~360 px, aligné à gauche. L'actif prend une surface qui SE
/// DÉTACHE de la piste, dans le sens inverse selon le mode :
///   • en CLAIR, plus CLAIRE : la carte (`colorScheme.surface`, blanc) sur la
///     piste grise (`trackMuted`) ;
///   • en SOMBRE, plus FONCÉE : le fond (`AppColors.background`) sur la piste.
/// ⚠ Inversion voulue — c'est le genre de règle qu'on « corrige » par erreur.
/// Sans ombre en clair : aucun token d'ombre n'existe (non tranché).
class _ModeSegmented extends ConsumerWidget {
  final ThemeMode mode;
  final bool isFr;
  const _ModeSegmented({required this.mode, required this.isFr});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final sem = theme.semantic;
    final items = [
      (ThemeMode.light, Icons.light_mode_rounded, isFr ? 'Clair' : 'Light'),
      (ThemeMode.dark, Icons.dark_mode_rounded, isFr ? 'Sombre' : 'Dark'),
      (ThemeMode.system, Icons.brightness_auto_rounded,
          isFr ? 'Système' : 'System'),
    ];
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: sem.trackMuted,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(children: [
            for (final (m, icon, label) in items)
              Expanded(
                child: _Segment(
                  icon: icon,
                  label: label,
                  active: mode == m,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    ref.read(themeModeProvider.notifier).setMode(m);
                  },
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _Segment({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    // Cf. l'inversion documentée sur `_ModeSegmented`.
    final activeFill = dark ? AppColors.background : cs.surface;
    final fg = active ? cs.onSurface : AppColors.textSecondary;
    return Semantics(
      selected: active,
      button: true,
      child: Material(
        color: active ? activeFill : Colors.transparent,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(9),
          child: ConstrainedBox(
            // 48 px au doigt (cf. `touch_target.dart`).
            constraints: BoxConstraints(
                minHeight: isTouchPlatform ? kMinTouchTarget : 36),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 16, color: fg),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: (active
                              ? AppTextStyles.bodySmBold
                              : AppTextStyles.bodySm)
                          .copyWith(color: fg)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// CARTE DE PALETTE COMPACTE : trois pavés, puis le nom et la sélection.
///
/// Sélectionnée : bordure de 2 px à la primaire, fond `brandSurface`, nom en
/// gras, coche pleine à la place du rond. Les pavés sont PLEINS, sans
/// dégradé : en clair, les anciens aperçus tiraient tous vers le blanc et
/// Ambre, Rose et Minuit se distinguaient à peine.
class _PaletteTile extends StatelessWidget {
  final ThemePalette palette;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _PaletteTile({
    required this.palette,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  static const double _kSwatch = 27;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final sem = theme.semantic;
    final sw = themeSwatches(palette, theme.brightness);

    Widget swatch(Color c, {bool bordered = false}) => Container(
          width: _kSwatch,
          height: _kSwatch,
          decoration: BoxDecoration(
            color: c,
            borderRadius: BorderRadius.circular(8),
            border: bordered ? Border.all(color: sem.borderSubtle) : null,
          ),
        );

    return Semantics(
      selected: selected,
      button: true,
      label: label,
      child: Material(
        color: selected ? sem.brandSurface : cs.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: selected ? cs.primary : sem.borderSubtle,
            width: selected ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(children: [
                  swatch(sw.text),
                  const SizedBox(width: 6),
                  swatch(sw.fill),
                  const SizedBox(width: 6),
                  swatch(sw.surface, bordered: true),
                ]),
                Row(children: [
                  Expanded(
                    child: Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: (selected
                                ? AppTextStyles.bodyBold
                                : AppTextStyles.body)
                            .copyWith(color: cs.onSurface)),
                  ),
                  Icon(
                    selected
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked_rounded,
                    size: 20,
                    color: selected ? cs.primary : AppColors.textSecondary,
                  ),
                ]),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
