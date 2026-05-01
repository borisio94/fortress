import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/theme/theme_palette.dart';
import '../../../../shared/widgets/app_scaffold.dart';

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
              Row(children: [
                Container(
                  width: 28, height: 28,
                  decoration: BoxDecoration(
                    color: current.primary.withOpacity(0.12),
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
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF0F172A))),
                      Text(l.paramThemeHint,
                          style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFF6B7280))),
                    ],
                  ),
                ),
              ]),
              const SizedBox(height: 14),
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
            ],
          );
        },
      ),
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
            color: palette.primary.withOpacity(0.25),
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
              color: Colors.white.withOpacity(0.2),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: Colors.white.withOpacity(0.35), width: 1.5),
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
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Colors.white.withOpacity(0.85),
                        letterSpacing: 0.5)),
                const SizedBox(height: 2),
                Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: Colors.white)),
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
                      color: palette.primary.withOpacity(0.18),
                      blurRadius: 14,
                      offset: const Offset(0, 6),
                    ),
                  ]
                : [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.03),
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
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
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
                    color: Colors.white.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Container(
                    height: 6,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.5),
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
                    color: palette.primary.withOpacity(0.15),
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
                color: Colors.white.withOpacity(0.85),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
