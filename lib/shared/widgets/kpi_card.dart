import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// Donnée d'affichage d'un KPI. Format neutre réutilisable partout
/// (dashboard, finances, etc.).
class KpiData {
  final String label;
  final String value;
  final String unit;            // ex: 'XAF' · '' si pas d'unité
  final IconData icon;
  final Color color;
  /// Variation (ex: '+12.5%'). Vide = pas de badge.
  final String delta;
  final bool positive;
  /// Texte secondaire optionnel (ex: "4 transactions", "vs période préc.").
  /// Affiché sous le label.
  final String subtext;
  /// Si vrai, un liseré rouge est affiché à gauche (alertes/erreurs).
  final bool errorIndicator;
  /// Si vrai, un liseré primary est affiché à gauche (card "sélectionnée").
  /// Prime sur [errorIndicator] si les deux sont à true.
  final bool active;
  final VoidCallback? onTap;

  const KpiData({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    this.unit = '',
    this.delta = '',
    this.positive = true,
    this.subtext = '',
    this.errorIndicator = false,
    this.active = false,
    this.onTap,
  });
}

/// Grille responsive de cartes KPI.
///
/// * Sur mobile (< [mobileBreakpoint] px) : **scroll horizontal** — évite
///   d'empiler 4+ cards en hauteur et garde la hero zone compacte.
///   Le scroll supporte touch, trackpad, drag souris ET molette verticale
///   (convertie en scroll horizontal).
/// * Sur desktop/tablette : **Wrap** qui calcule le nombre de colonnes pour
///   respecter [minCardWidth].
///
/// Aucune hauteur fixe dans les deux cas — la card s'adapte à son contenu.
class KpiGrid extends StatefulWidget {
  final List<KpiData> kpis;
  final double minCardWidth;
  final double spacing;
  final double mobileBreakpoint;

  const KpiGrid({
    super.key,
    required this.kpis,
    this.minCardWidth = 140,
    this.spacing = 10,
    this.mobileBreakpoint = 600,
  });

  @override
  State<KpiGrid> createState() => _KpiGridState();
}

class _KpiGridState extends State<KpiGrid> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Convertit un scroll vertical de la molette en scroll horizontal,
  /// indispensable car Flutter n'applique pas la molette verticale à un
  /// `SingleChildScrollView` horizontal par défaut.
  void _onPointerSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    if (!_scroll.hasClients) return;
    final dx = e.scrollDelta.dx != 0 ? e.scrollDelta.dx : e.scrollDelta.dy;
    final target = (_scroll.offset + dx)
        .clamp(_scroll.position.minScrollExtent,
               _scroll.position.maxScrollExtent);
    _scroll.jumpTo(target);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.kpis.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(builder: (context, constraints) {
      final available = constraints.maxWidth;

      // ── Mobile / fenêtre étroite : scroll horizontal ────────────────────
      if (available < widget.mobileBreakpoint) {
        // ScrollConfiguration pour accepter touch + souris + trackpad
        // (sur desktop, Flutter bloque le drag souris par défaut).
        final behavior = ScrollConfiguration.of(context).copyWith(
          scrollbars: false,
          overscroll: false,
          dragDevices: const {
            PointerDeviceKind.touch,
            PointerDeviceKind.mouse,
            PointerDeviceKind.trackpad,
            PointerDeviceKind.stylus,
            PointerDeviceKind.invertedStylus,
          },
        );
        return Listener(
          onPointerSignal: _onPointerSignal,
          child: ScrollConfiguration(
            behavior: behavior,
            child: SingleChildScrollView(
              controller: _scroll,
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(
                  parent: ClampingScrollPhysics()),
              padding: EdgeInsets.zero,
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < widget.kpis.length; i++) ...[
                      if (i > 0) SizedBox(width: widget.spacing),
                      SizedBox(
                        width: widget.minCardWidth,
                        child: KpiCard(data: widget.kpis[i]),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      }

      // ── Desktop / tablette : Wrap (colonnes calculées) ───────────────────
      final cols = ((available + widget.spacing) /
              (widget.minCardWidth + widget.spacing))
          .floor()
          .clamp(1, widget.kpis.length);
      final totalSpacing = (cols - 1) * widget.spacing;
      final cardW = ((available - totalSpacing) / cols)
          .floorToDouble()
          .clamp(widget.minCardWidth, double.infinity);

      return Wrap(
        spacing: widget.spacing,
        runSpacing: widget.spacing,
        children: widget.kpis
            .map((k) => SizedBox(width: cardW, child: KpiCard(data: k)))
            .toList(),
      );
    });
  }
}

/// Carte KPI unifiée — icône, valeur, label, delta et onTap optionnels.
/// Utilisée par `KpiGrid`, mais aussi utilisable seule.
class KpiCard extends StatelessWidget {
  final KpiData data;
  const KpiCard({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final hasDelta    = data.delta.isNotEmpty;
    final hasSubtext  = data.subtext.isNotEmpty;
    final clickable   = data.onTap != null;
    // L'état "actif" (onglet sélectionné) prime sur l'indicateur d'erreur.
    final leftAccent  = data.active
        ? AppColors.primary
        : (data.errorIndicator ? AppColors.error : null);

    final inner = Padding(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              Container(
                width: 28, height: 28,
                decoration: BoxDecoration(
                  color: data.color.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Icon(data.icon, size: 14, color: data.color),
              ),
              const Spacer(),
              if (hasDelta)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: (data.positive
                            ? AppColors.secondary
                            : AppColors.error)
                        .withOpacity(0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(
                      data.positive
                          ? Icons.arrow_upward_rounded
                          : Icons.arrow_downward_rounded,
                      size: 10,
                      color: data.positive
                          ? AppColors.secondary : AppColors.error,
                    ),
                    const SizedBox(width: 2),
                    Text(data.delta,
                        style: TextStyle(
                            fontSize: 9, fontWeight: FontWeight.w700,
                            color: data.positive
                                ? AppColors.secondary
                                : AppColors.error)),
                  ]),
                ),
            ]),
            const SizedBox(height: 8),
            Text(
              data.unit.isNotEmpty
                  ? '${data.value} ${data.unit}'
                  : data.value,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w800,
                  color: data.color),
            ),
            const SizedBox(height: 2),
            Text(data.label,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textSecondary)),
            if (hasSubtext) ...[
              const SizedBox(height: 2),
              Text(data.subtext,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 10, color: AppColors.textHint)),
            ],
          ]),
    );

    // Liseré gauche simulé via un Container adjacent — éviter de mélanger
    // `BorderSide(width: 0)` avec `borderRadius` (interdit par Flutter).
    final decorated = Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03),
            blurRadius: 4, offset: const Offset(0, 2))],
      ),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (leftAccent != null)
                Container(width: 3, color: leftAccent),
              Expanded(child: inner),
            ]),
      ),
    );

    if (!clickable) return decorated;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: data.onTap,
        borderRadius: BorderRadius.circular(12),
        child: decorated,
      ),
    );
  }
}
