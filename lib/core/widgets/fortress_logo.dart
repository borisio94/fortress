import 'package:flutter/material.dart';

/// Logo Fortress dessiné via [CustomPainter] — bouclier + sabres croisés +
/// cercle central + checkmark. Coordonnées normalisées dans un espace 0..120
/// (Y vers le bas), mises à l'échelle par `size / 120`.
///
/// Trois variantes prêtes à l'emploi :
/// - [FortressLogo.dark]  — sur fond sombre (splash, sidebar, drawer)
/// - [FortressLogo.light] — sur fond clair (login, fond blanc)
/// - [FortressLogo.mono]  — noir sur blanc (PDF, impression)
///
/// Le widget peint uniquement l'icône — il ne rend AUCUN background opaque
/// derrière le bouclier. Pour obtenir le bloc visuel complet (rounded
/// rect violet/sombre des PNG), wrapper dans un `Container` avec
/// `decoration` côté appelant.
class FortressLogo extends StatelessWidget {
  final double size;

  /// Couleur principale (bouclier + cercle stroke). `null` → théme primary.
  final Color? primaryColor;

  /// Couleur des sabres. `null` → const Color(0xFFC8B97A) (or doré).
  final Color? swordColor;

  /// Fond du PETIT cercle central (pas du widget entier). Permet d'avoir
  /// un check contrasté quel que soit le fond du parent.
  final Color bgColor;

  /// Couleur du checkmark. `null` → blanc si [bgColor] est sombre, sinon
  /// la même que [primaryColor].
  final Color? checkColor;

  const FortressLogo({
    super.key,
    this.size = 80,
    this.primaryColor,
    this.swordColor,
    this.bgColor = Colors.white,
    this.checkColor,
  });

  /// Variante fond sombre (#1a1a2e). Splash, sidebar, drawer mobile.
  const FortressLogo.dark({super.key, this.size = 80})
      : primaryColor = const Color(0xFF534AB7),
        swordColor   = const Color(0xFFC8B97A),
        bgColor      = const Color(0xFF1A1A2E),
        checkColor   = Colors.white;

  /// Variante fond clair. Login, documents, fond blanc.
  ///
  /// `primaryColor` reste null → résolu via `Theme.of(context).colorScheme.primary`
  /// dans [build]. Le checkmark s'aligne automatiquement sur primaryColor
  /// (sinon il serait blanc sur blanc, invisible).
  const FortressLogo.light({super.key, this.size = 80})
      : primaryColor = null,
        swordColor   = const Color(0xFFC8B97A),
        bgColor      = Colors.white,
        checkColor   = null;

  /// Variante monochrome noire. PDF factures, impression noir & blanc.
  const FortressLogo.mono({super.key, this.size = 80})
      : primaryColor = Colors.black,
        swordColor   = Colors.black,
        bgColor      = Colors.white,
        checkColor   = Colors.black;

  @override
  Widget build(BuildContext context) {
    final p = primaryColor ?? Theme.of(context).colorScheme.primary;
    final s = swordColor ?? const Color(0xFFC8B97A);
    // Auto-résolution check : si pas spécifié, on prend white sur fond
    // sombre, primary sur fond clair (luminance < 0.5 = sombre).
    final c = checkColor ??
        (bgColor.computeLuminance() < 0.5 ? Colors.white : p);
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        size: Size.square(size),
        painter: _FortressPainter(
          primary: p, sword: s, bg: bgColor, check: c, sizePx: size,
        ),
      ),
    );
  }
}

class _FortressPainter extends CustomPainter {
  final Color primary, sword, bg, check;
  final double sizePx;

  _FortressPainter({
    required this.primary,
    required this.sword,
    required this.bg,
    required this.check,
    required this.sizePx,
  });

  @override
  void paint(Canvas canvas, Size canvasSize) {
    final s = canvasSize.width / 120.0;
    Offset p(double x, double y) => Offset(x * s, y * s);

    // ── 1. Bouclier ────────────────────────────────────────────────
    // Path : M60,10 L98,26 L98,66 C98,88 82,100 60,110
    //        C38,100 22,88 22,66 L22,26 Z
    final shield = Path()
      ..moveTo(60 * s, 10 * s)
      ..lineTo(98 * s, 26 * s)
      ..lineTo(98 * s, 66 * s)
      ..cubicTo(98 * s, 88 * s, 82 * s, 100 * s, 60 * s, 110 * s)
      ..cubicTo(38 * s, 100 * s, 22 * s, 88 * s, 22 * s, 66 * s)
      ..lineTo(22 * s, 26 * s)
      ..close();

    // Remplissage intérieur (15% d'opacité)
    canvas.drawPath(shield, Paint()
      ..color = primary.withValues(alpha: 0.15)
      ..style = PaintingStyle.fill);

    // Contour
    canvas.drawPath(shield, Paint()
      ..color = primary
      ..style = PaintingStyle.stroke
      ..strokeWidth = sizePx * 0.021
      ..strokeJoin = StrokeJoin.round);

    // ── 2-3. Sabres : gauche (38,32)→(76,82) · droit (82,32)→(44,82) ─
    final blade = Paint()
      ..color = sword
      ..strokeWidth = sizePx * 0.025
      ..strokeCap = StrokeCap.butt;
    final fillSword = Paint()..color = sword;

    void drawSabre(
      Offset tip, Offset handle,
      List<Offset> tipTri,
    ) {
      // Lame
      canvas.drawLine(tip, handle, blade);
      // Pointe (triangle plein)
      canvas.drawPath(
        Path()
          ..moveTo(tipTri[0].dx, tipTri[0].dy)
          ..lineTo(tipTri[1].dx, tipTri[1].dy)
          ..lineTo(tipTri[2].dx, tipTri[2].dy)
          ..close(),
        fillSword,
      );
      // Garde : petit cercle aux 3/4 du chemin (côté handle)
      final gx = tip.dx * 0.25 + handle.dx * 0.75;
      final gy = tip.dy * 0.25 + handle.dy * 0.75;
      canvas.drawCircle(Offset(gx, gy), sizePx * 0.025, fillSword);
    }

    drawSabre(
      p(38, 32), p(76, 82),
      [p(38, 32), p(31, 44), p(43, 40)],
    );
    drawSabre(
      p(82, 32), p(44, 82),
      [p(82, 32), p(75, 44), p(87, 40)],
    );

    // ── 4. Cercle central (par-dessus les sabres) ────────────────────
    final cc = p(60, 68);
    final r = 14 * s;
    canvas.drawCircle(cc, r, Paint()..color = bg);
    canvas.drawCircle(cc, r, Paint()
      ..color = primary
      ..style = PaintingStyle.stroke
      ..strokeWidth = sizePx * 0.017);

    // ── 5. Checkmark : M54,68 L59,74 L68,58 ──────────────────────────
    final checkPath = Path()
      ..moveTo(54 * s, 68 * s)
      ..lineTo(59 * s, 74 * s)
      ..lineTo(68 * s, 58 * s);
    canvas.drawPath(checkPath, Paint()
      ..color = check
      ..style = PaintingStyle.stroke
      ..strokeWidth = sizePx * 0.023
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round);
  }

  @override
  bool shouldRepaint(_FortressPainter old) =>
      old.primary != primary ||
      old.sword != sword ||
      old.bg != bg ||
      old.check != check ||
      old.sizePx != sizePx;
}
