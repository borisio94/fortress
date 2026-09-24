import 'package:flutter/material.dart';

import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';

/// Contour POINTILLÉ du mode restaurant.
///
/// Il marque ce qui ne se CHOISIT pas mais s'OUVRE ou se CRÉE : « Personnalisé »
/// dans la feuille de période, les cases de création en fin de liste ou de
/// grille ([RestoAddCell]). La forme le dit avant qu'on touche.
class RestoDashedBorder extends StatelessWidget {
  final Widget child;
  final Color color;
  final double radius;

  const RestoDashedBorder({
    super.key,
    required this.child,
    required this.color,
    required this.radius,
  });

  @override
  Widget build(BuildContext context) => CustomPaint(
        foregroundPainter: _DashedPainter(color: color, radius: radius),
        child: child,
      );
}

class _DashedPainter extends CustomPainter {
  final Color color;
  final double radius;

  const _DashedPainter({required this.color, required this.radius});

  /// Tiret et espace. Courts sur un petit rayon : plus longs, les angles
  /// arrondis les cassent en plein milieu.
  static const double _dash = 4;
  static const double _gap = 3.5;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    // Rentré d'une demi-épaisseur : sinon la moitié du trait tombe hors de la
    // cellule et se fait rogner.
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(0.6), Radius.circular(radius)));
    for (final metric in path.computeMetrics()) {
      var dist = 0.0;
      while (dist < metric.length) {
        final end = (dist + _dash).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(dist, end), paint);
        dist = end + _gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedPainter old) =>
      old.color != color || old.radius != radius;
}

/// LA CASE DE CRÉATION, en fin de liste ou de grille.
///
/// ─── RÈGLE DES QUATRE ÉCRANS (24/09/2026) ─────────────────────────────────
///
/// Commandes, Plan de salle, Menu et Stock : UNE SEULE porte de création, cette
/// case pointillée en fin de liste ou de grille. PAS de bouton d'en-tête en
/// plus — jamais deux appels à la même action à quinze centimètres. L'ÉTAT
/// VIDE garde son propre bouton : sans rien à lister, il n'y a pas de « fin de
/// liste » où poser la case.
///
/// Toutes les largeurs, sans branche mobile : la grammaire est la même.
///
/// Pointillée parce qu'elle n'est pas un élément de plus : elle en fabrique un.
/// Elle prend la taille que son parent lui donne — une cellule de grille, ou
/// une ligne de liste.
class RestoAddCell extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final double radius;

  const RestoAddCell({
    super.key,
    required this.label,
    required this.onTap,
    this.radius = 10,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    return RestoDashedBorder(
      color: sem.borderSubtle,
      radius: radius,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(radius),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(radius),
          child: Center(
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.add_rounded, size: 18, color: cs.primary),
              const SizedBox(width: 4),
              Text(label,
                  style: AppTextStyles.bodyBold.copyWith(color: cs.primary)),
            ]),
          ),
        ),
      ),
    );
  }
}
