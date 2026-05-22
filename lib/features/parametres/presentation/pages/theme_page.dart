import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/logo_theme_builder.dart';
import '../../../../core/theme/theme_palette.dart';
import '../../../../core/theme/theme_mode_provider.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../caisse/presentation/widgets/empty_cart_dashboard.dart';

class ThemePage extends ConsumerWidget {
  final String? shopId;
  const ThemePage({super.key, this.shopId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final isFr = Localizations.localeOf(context).languageCode == 'fr';
    final current = ref.watch(themePaletteProvider);

    return AppScaffold(
      shopId: shopId ?? '',
      title: l.paramTheme,
      isRootPage: false,
      body: LayoutBuilder(
        builder: (context, constraints) {
          // Calcule un nombre de colonnes responsive
          final w = constraints.maxWidth;
          final cols = w >= 1100
              ? 4
              : w >= 760
                  ? 3
                  : 2;

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              _Header(palette: current, label: current.label(isFr)),
              const SizedBox(height: 18),
              // Sélecteur clair / sombre / système masqué tant que le mode
              // sombre n'est pas finalisé (le rendu est forcé clair dans
              // app.dart). Réactiver en décommentant la ligne ci-dessous.
              // _ModeSelector(primary: current.primary, isFr: isFr),
              // const SizedBox(height: 18),
              Row(children: [
                Container(
                  width: 28, height: 28,
                  decoration: BoxDecoration(
                    color: current.primary.withValues(alpha:0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(Icons.palette_outlined,
                      size: 16, color: current.primary),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l.paramThemeSubtitle,
                          style: AppTextStyles.bodyBold),
                      Text(l.paramThemeHint,
                          style: AppTextStyles.caption),
                    ],
                  ),
                ),
              ]),
              const SizedBox(height: 14),
              // Card « Généré depuis votre logo » — visible uniquement
              // si l'utilisateur a déjà importé un logo et qu'on a pu
              // en dériver une palette exploitable (cache présent).
              _LogoGeneratedCard(
                current: current,
                onTap: (palette) {
                  HapticFeedback.selectionClick();
                  ref.read(themePaletteProvider.notifier)
                      .setPalette(palette);
                },
              ),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: cols,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 0.92,
                ),
                itemCount: kAllPalettes.length,
                itemBuilder: (context, i) {
                  final p = kAllPalettes[i];
                  return _PaletteCard(
                    palette: p,
                    selected: current.id == p.id,
                    label: p.label(isFr),
                    onTap: () {
                      HapticFeedback.selectionClick();
                      ref
                          .read(themePaletteProvider.notifier)
                          .setPalette(p);
                    },
                  );
                },
              ),
              const SizedBox(height: 24),
              const _EmptyDashboardToggle(),
            ],
          );
        },
      ),
    );
  }
}

// ─── Toggle « Tableau de bord dans le panier vide » ────────────────────────
//
// Persisté dans la box Hive globale `settings_box` via les helpers exposés
// par `empty_cart_dashboard.dart`. Pas de provider Riverpod — on lit/écrit
// directement, le rebuild du panier prend le relais à la prochaine entrée
// dans la caisse.
class _EmptyDashboardToggle extends StatefulWidget {
  const _EmptyDashboardToggle();
  @override
  State<_EmptyDashboardToggle> createState() => _EmptyDashboardToggleState();
}

class _EmptyDashboardToggleState extends State<_EmptyDashboardToggle> {
  late bool _enabled = isEmptyCartDashboardEnabled();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final sem   = theme.semantic;
    final l     = context.l10n;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: sem.borderSubtle),
      ),
      child: Row(children: [
        Container(
          width: 28, height: 28,
          decoration: BoxDecoration(
            color: cs.primary.withValues(alpha:0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(Icons.dashboard_customize_outlined,
              size: 16, color: cs.primary),
        ),
        const SizedBox(width: 10),
        Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
          Text(l.settingsEmptyDashboardToggle,
              style: AppTextStyles.bodyBold.copyWith(color: cs.onSurface)),
          Text(l.settingsEmptyDashboardHint,
              style: AppTextStyles.caption.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.6))),
        ])),
        Switch(
          value: _enabled,
          onChanged: (v) async {
            await setEmptyCartDashboardEnabled(v);
            if (mounted) setState(() => _enabled = v);
          },
        ),
      ]),
    );
  }
}

// ─── Header avec aperçu live de la palette active ───────────────────────────

class _Header extends StatelessWidget {
  final ThemePalette palette;
  final String label;
  const _Header({required this.palette, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: palette.previewGradient,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: palette.primary.withValues(alpha:0.25),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 56, height: 56,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha:0.2),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: Colors.white.withValues(alpha:0.35), width: 1.5),
            ),
            child: const Icon(Icons.color_lens_rounded,
                color: Colors.white, size: 26),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Thème actif',
                    style: AppTextStyles.captionBold.copyWith(
                        color: Colors.white.withValues(alpha:0.85),
                        letterSpacing: 0.5)),
                const SizedBox(height: 2),
                Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.title.copyWith(color: Colors.white)),
                const SizedBox(height: 8),
                Row(children: [
                  _MiniDot(palette.primary),
                  const SizedBox(width: 5),
                  _MiniDot(palette.primaryLight),
                  const SizedBox(width: 5),
                  _MiniDot(palette.primaryDark),
                  const SizedBox(width: 5),
                  _MiniDot(palette.primarySurface),
                ]),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniDot extends StatelessWidget {
  final Color color;
  const _MiniDot(this.color);
  @override
  Widget build(BuildContext context) => Container(
        width: 16, height: 16,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 1.5),
        ),
      );
}

// ─── Card « Généré depuis votre logo » ──────────────────────────────────────
//
// N'apparaît que si une palette dérivée d'un logo est mise en cache
// (cf. `ShopLogoSection._applyLogoToTheme`). Au tap, applique cette
// palette via `setPalette(palette)`. Si l'utilisateur supprime son
// logo, le cache est purgé et la card disparaît.
class _LogoGeneratedCard extends StatelessWidget {
  final ThemePalette current;
  final void Function(ThemePalette palette) onTap;
  const _LogoGeneratedCard({required this.current, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final palette = ThemePaletteNotifier.cachedLogoPalette();
    if (palette == null) return const SizedBox.shrink();
    final selected = current.id == LogoThemeBuilder.generatedId;
    final theme = Theme.of(context);
    final primary = palette.primary;
    final secondary = palette.previewGradient.length > 1
        ? palette.previewGradient[1]
        : palette.primaryLight;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => onTap(palette),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: selected
                    ? primary.withValues(alpha: 0.6)
                    : Colors.black.withValues(alpha: 0.06),
                width: selected ? 2 : 1,
              ),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: primary.withValues(alpha: 0.18),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : null,
            ),
            child: Row(children: [
              // Cercle bicolore : 2 demi-disques (primary + secondary).
              SizedBox(
                width: 56, height: 56,
                child: Stack(children: [
                  // Disque secondary (fond)
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        color: secondary,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  // Demi-disque primary (clipé moitié gauche)
                  Positioned.fill(
                    child: ClipPath(
                      clipper: _HalfCircleClipper(),
                      child: Container(color: primary),
                    ),
                  ),
                  // Bordure
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: Colors.white, width: 2),
                      ),
                    ),
                  ),
                ]),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Votre logo',
                        style: AppTextStyles.bodyBold.copyWith(
                            color: theme.colorScheme.onSurface)),
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: primary.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        'Généré depuis votre logo',
                        style: AppTextStyles.caption.copyWith(
                            color: primary,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
              if (selected)
                Icon(Icons.check_circle_rounded,
                    color: primary, size: 22),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Clipper qui ne garde que la moitié gauche d'un cercle — utilisé
/// pour le rendu bicolore primary/secondary de la card logo.
class _HalfCircleClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    return Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width / 2, size.height));
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

// ─── Card de palette individuelle avec mini-mockup UI ───────────────────────

class _PaletteCard extends StatelessWidget {
  final ThemePalette palette;
  final bool selected;
  final String label;
  final VoidCallback onTap;

  const _PaletteCard({
    required this.palette,
    required this.selected,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected
                  ? palette.primary
                  : const Color(0xFFE5E7EB),
              width: selected ? 2 : 1,
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: palette.primary.withValues(alpha:0.18),
                      blurRadius: 14,
                      offset: const Offset(0, 6),
                    ),
                  ]
                : [
                    BoxShadow(
                      color: Colors.black.withValues(alpha:0.03),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Aperçu du thème — mini-mockup d'app
              Expanded(
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(15)),
                  child: _PaletteMockup(
                      palette: palette, selected: selected),
                ),
              ),
              // Footer avec nom + check
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.bodyBold.copyWith(
                          color: selected
                              ? palette.primary
                              : const Color(0xFF0F172A),
                        ),
                      ),
                    ),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: 22, height: 22,
                      decoration: BoxDecoration(
                        color: selected
                            ? palette.primary
                            : const Color(0xFFF3F4F6),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        selected
                            ? Icons.check_rounded
                            : Icons.circle_outlined,
                        size: 14,
                        color: selected
                            ? Colors.white
                            : const Color(0xFFD1D5DB),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Mini-mockup UI affiché dans la card (header coloré + tile + bouton) ────

class _PaletteMockup extends StatelessWidget {
  final ThemePalette palette;
  final bool selected;
  const _PaletteMockup(
      {required this.palette, required this.selected});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            palette.primarySurface,
            Colors.white,
          ],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Faux AppBar
          Container(
            height: 24,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: palette.previewGradient,
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              ),
              borderRadius: BorderRadius.circular(6),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(
              children: [
                Container(
                  width: 14, height: 14,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha:0.3),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Container(
                    height: 6,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha:0.5),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          // Faux KPI card
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFFE5E7EB)),
            ),
            child: Row(
              children: [
                Container(
                  width: 16, height: 16,
                  decoration: BoxDecoration(
                    color: palette.primary.withValues(alpha:0.15),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Icon(Icons.bolt_rounded,
                      size: 10, color: palette.primary),
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 28, height: 4,
                        color: const Color(0xFF111827),
                      ),
                      const SizedBox(height: 2),
                      Container(
                        width: 16, height: 3,
                        color: const Color(0xFF9CA3AF),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          // Faux bouton primaire
          Container(
            height: 18,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: palette.primary,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Container(
              width: 28, height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha:0.85),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Sélecteur de mode (Clair / Sombre / Système) ───────────────────────────
// Conservé pour réactivation quand le mode sombre sera finalisé (cf.
// theme_page build + app.dart). Masqué de l'UI pour l'instant.
// ignore: unused_element
class _ModeSelector extends ConsumerWidget {
  final Color primary;
  final bool isFr;
  const _ModeSelector({required this.primary, required this.isFr});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Container(
            width: 28, height: 28,
            decoration: BoxDecoration(
              color: primary.withValues(alpha:0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(Icons.brightness_6_rounded, size: 16, color: primary),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(isFr ? 'Apparence' : 'Appearance',
                    style: AppTextStyles.bodyBold),
                Text(
                    isFr
                        ? 'Mode clair, sombre ou suivre le système.'
                        : 'Light, dark or follow system.',
                    style: AppTextStyles.caption),
              ],
            ),
          ),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
              child: _ModeCard(
                  icon: Icons.light_mode_rounded,
                  label: isFr ? 'Clair' : 'Light',
                  selected: mode == ThemeMode.light,
                  primary: primary,
                  onTap: () => ref
                      .read(themeModeProvider.notifier)
                      .setMode(ThemeMode.light))),
          const SizedBox(width: 8),
          Expanded(
              child: _ModeCard(
                  icon: Icons.dark_mode_rounded,
                  label: isFr ? 'Sombre' : 'Dark',
                  selected: mode == ThemeMode.dark,
                  primary: primary,
                  onTap: () => ref
                      .read(themeModeProvider.notifier)
                      .setMode(ThemeMode.dark))),
          const SizedBox(width: 8),
          Expanded(
              child: _ModeCard(
                  icon: Icons.brightness_auto_rounded,
                  label: isFr ? 'Système' : 'System',
                  selected: mode == ThemeMode.system,
                  primary: primary,
                  onTap: () => ref
                      .read(themeModeProvider.notifier)
                      .setMode(ThemeMode.system))),
        ]),
      ],
    );
  }
}

class _ModeCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final Color primary;
  final VoidCallback onTap;
  const _ModeCard({
    required this.icon,
    required this.label,
    required this.selected,
    required this.primary,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
          decoration: BoxDecoration(
            color: selected ? primary.withValues(alpha:0.08) : Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? primary : const Color(0xFFE5E7EB),
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 22,
                  color: selected ? primary : const Color(0xFF6B7280)),
              const SizedBox(height: 6),
              Text(label,
                  style: AppTextStyles.bodySm.copyWith(
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                    color: selected ? primary : const Color(0xFF374151),
                  )),
            ],
          ),
        ),
      ),
    );
  }
}
