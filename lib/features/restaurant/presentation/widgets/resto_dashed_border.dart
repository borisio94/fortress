import 'package:flutter/material.dart';


/// Contour POINTILLÉ du mode restaurant.
///
/// Il marque ce qui ne se CHOISIT pas mais s'OUVRE : « Personnalisé » dans la
/// feuille de période (`resto_period_sheet.dart`). La forme le dit avant qu'on
/// touche.
///
/// ⚠ NE PAS SUPPRIMER EN CROYANT NETTOYER : les cases de création en fin de
/// liste (`RestoAddCell`) ont disparu le 24/09/2026, remplacées par le bouton
/// flottant (`RestoFab`), mais la feuille de période l'emploie toujours.
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
