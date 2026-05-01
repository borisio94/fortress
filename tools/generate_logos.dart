// Génère les 6 logos PNG Fortress + l'icône app — pur Dart, sans Python.
//
// Lancer depuis la racine du projet :
//   dart run tools/generate_logos.dart
//
// Trade-off polices : `package:image` ne fournit que arial14/24/48 en
// fontes embarquées. Georgia (spec serif) n'est pas disponible sans TTF
// custom, donc on substitue arial48 + upscale via `copyResize` pour
// approcher les tailles 38/64px. La typographie sera visuellement
// proche mais pas identique au spec — accepté car contrainte
// d'environnement (pas de Pillow / pas de Python).
//
// Note d'archi : le package `image` 4.x active `BlendMode.alpha` par
// défaut sur fillPolygon/drawLine/fillCircle → pas besoin de l'astuce
// "overlay + alpha_composite" qu'on faisait sous Pillow ; les couleurs
// semi-transparentes blendent correctement source-over.

import 'dart:io';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

// ── Sortie ──────────────────────────────────────────────────────────────
final outDir = p.join(Directory.current.path, 'assets', 'logos');

// ── Palette ─────────────────────────────────────────────────────────────
img.Color rgba(int r, int g, int b, [int a = 255]) => img.ColorRgba8(r, g, b, a);
img.Color withAlpha(int r, int g, int b, double a) =>
    img.ColorRgba8(r, g, b, (a * 255).round());

final night    = rgba(26, 26, 46);     // #1a1a2e
final primary  = rgba(83, 74, 183);    // #534AB7
final primaryL = rgba(123, 115, 212);  // #7B73D4
final gold     = rgba(200, 185, 122);  // #C8B97A
final goldL    = rgba(232, 212, 154);  // #E8D49A
final goldDark = rgba(168, 144, 96);   // #A89060
final goldGuard = rgba(200, 168, 96);  // #C8A860
final grey44   = rgba(68, 68, 68);     // #444444
final greyBord = rgba(224, 224, 224);  // #e0e0e0
final white    = rgba(255, 255, 255);

// ── Bézier cubique (4 points, n samples) ────────────────────────────────
List<List<double>> cubic(
    List<double> p0, List<double> p1, List<double> p2, List<double> p3,
    [int n = 40]) {
  final pts = <List<double>>[];
  for (var i = 0; i <= n; i++) {
    final t = i / n;
    final u = 1 - t;
    final u2 = u * u, u3 = u2 * u, t2 = t * t, t3 = t2 * t;
    final x = u3 * p0[0] + 3 * u2 * t * p1[0] + 3 * u * t2 * p2[0] + t3 * p3[0];
    final y = u3 * p0[1] + 3 * u2 * t * p1[1] + 3 * u * t2 * p2[1] + t3 * p3[1];
    pts.add([x, y]);
  }
  return pts;
}

// Polygone du bouclier (espace logique 0..120, Y vers le bas)
final shieldOutline = <List<double>>[
  [60, 10], [98, 26], [98, 66],
  ...cubic([98, 66], [98, 88], [82, 100], [60, 110]).skip(1),
  ...cubic([60, 110], [38, 100], [22, 88], [22, 66]).skip(1),
  [22, 26],
];

// ── Mapper coordonnées logiques → pixels ────────────────────────────────
class Mapper {
  final double scale, x0, y0;
  Mapper(double cx, double cy, double size)
      : scale = size / 120.0,
        x0 = cx - size / 2,
        y0 = cy - size / 2;

  img.Point pt(double x, double y) =>
      img.Point((x0 + x * scale).round(), (y0 + y * scale).round());
}

// ── Thème par version ───────────────────────────────────────────────────
class LogoTheme {
  final img.Color shieldStroke;
  final num shieldStrokeW;
  final img.Color shieldFill;
  final img.Color sabre;
  final num sabreW;
  final img.Color garde;
  final num gardeW;
  final img.Color circleStroke;
  final num circleStrokeW;
  final img.Color circleFill;
  final img.Color check;
  final num checkW;

  const LogoTheme({
    required this.shieldStroke,
    required this.shieldStrokeW,
    required this.shieldFill,
    required this.sabre,
    required this.sabreW,
    required this.garde,
    required this.gardeW,
    required this.circleStroke,
    required this.circleStrokeW,
    required this.circleFill,
    required this.check,
    required this.checkW,
  });
}

// ── Helpers de dessin ───────────────────────────────────────────────────

/// Cercle à contour épais : empile N drawCircle (radius − 0..thickness).
/// drawCircle 4.x n'a pas de paramètre `thickness` — on simule.
void drawThickCircle(img.Image image, int cx, int cy, int radius,
    img.Color color, int thickness) {
  for (var i = 0; i < thickness; i++) {
    img.drawCircle(image,
        x: cx, y: cy, radius: radius - i, color: color, antialias: true);
  }
}

void drawLogo(img.Image image, double cx, double cy, double size, LogoTheme t) {
  final m = Mapper(cx, cy, size);
  final s = size / 120.0;
  final vertices = shieldOutline.map((q) => m.pt(q[0], q[1])).toList();

  // 1. Remplissage bouclier (alpha-blend natif)
  img.fillPolygon(image, vertices: vertices, color: t.shieldFill);

  // 2. Contour bouclier
  img.drawPolygon(image,
      vertices: vertices,
      color: t.shieldStroke,
      thickness: (t.shieldStrokeW * s).clamp(1, 999),
      antialias: true);

  // 3. Sabres : (38,32)→(76,82) et (82,32)→(44,82)
  final sabreThickness = (t.sabreW * s).clamp(1, 999).round();
  final gardeRadius = (t.gardeW * s).clamp(1, 999).round();
  final pairs = [
    [
      [38.0, 32.0], [76.0, 82.0],
      [[38.0, 32.0], [31.0, 44.0], [43.0, 40.0]],
    ],
    [
      [82.0, 32.0], [44.0, 82.0],
      [[82.0, 32.0], [75.0, 44.0], [87.0, 40.0]],
    ],
  ];
  for (final pair in pairs) {
    final tip = pair[0] as List<double>;
    final handle = pair[1] as List<double>;
    final tri = pair[2] as List<List<double>>;

    final pTip = m.pt(tip[0], tip[1]);
    final pHandle = m.pt(handle[0], handle[1]);

    // Lame
    img.drawLine(image,
        x1: pTip.x.toInt(), y1: pTip.y.toInt(),
        x2: pHandle.x.toInt(), y2: pHandle.y.toInt(),
        color: t.sabre, thickness: sabreThickness, antialias: true);

    // Pointe (triangle plein)
    img.fillPolygon(image,
        vertices: tri.map((v) => m.pt(v[0], v[1])).toList(),
        color: t.sabre);

    // Garde : petit cercle aux 3/4 du chemin (côté handle)
    final gx = tip[0] * 0.25 + handle[0] * 0.75;
    final gy = tip[1] * 0.25 + handle[1] * 0.75;
    final pGarde = m.pt(gx, gy);
    img.fillCircle(image,
        x: pGarde.x.toInt(), y: pGarde.y.toInt(),
        radius: gardeRadius, color: t.garde, antialias: true);
  }

  // 4. Cercle central (par-dessus les sabres)
  final pc = m.pt(60, 68);
  final r = (14 * s).round();
  final csw = (t.circleStrokeW * s).clamp(1, 999).round();
  img.fillCircle(image,
      x: pc.x.toInt(), y: pc.y.toInt(),
      radius: r, color: t.circleFill, antialias: true);
  drawThickCircle(image, pc.x.toInt(), pc.y.toInt(), r, t.circleStroke, csw);

  // 5. Checkmark : M54,68 L59,74 L68,58 — 2 segments
  final c0 = m.pt(54, 68);
  final c1 = m.pt(59, 74);
  final c2 = m.pt(68, 58);
  final cw = (t.checkW * s).clamp(2, 999).round();
  img.drawLine(image,
      x1: c0.x.toInt(), y1: c0.y.toInt(),
      x2: c1.x.toInt(), y2: c1.y.toInt(),
      color: t.check, thickness: cw, antialias: true);
  img.drawLine(image,
      x1: c1.x.toInt(), y1: c1.y.toInt(),
      x2: c2.x.toInt(), y2: c2.y.toInt(),
      color: t.check, thickness: cw, antialias: true);
}

// ── Texte avec letter-spacing manuel ────────────────────────────────────

/// Largeur d'un caractère dans une fonte bitmap.
int _charWidth(img.BitmapFont font, int codeUnit) {
  final ch = font.characters[codeUnit];
  return ch?.width ?? 0;
}

/// Largeur totale d'une chaîne avec letter-spacing.
int _stringWidth(img.BitmapFont font, String text, int spacing) {
  var w = 0;
  for (var i = 0; i < text.length; i++) {
    w += _charWidth(font, text.codeUnitAt(i));
    if (i < text.length - 1) w += spacing;
  }
  return w;
}

/// Dessine `text` caractère par caractère pour gérer le letter-spacing.
/// `xy` = position de l'ancrage. `centerX` = xy.x est le centre horizontal.
void drawSpacedText(img.Image image, String text, img.BitmapFont font,
    {required int x, required int y,
    required img.Color color,
    int spacing = 0,
    bool centerX = false}) {
  var cursor = centerX
      ? x - _stringWidth(font, text, spacing) ~/ 2
      : x;
  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    img.drawString(image, ch, font: font, x: cursor, y: y, color: color);
    cursor += _charWidth(font, text.codeUnitAt(i)) + spacing;
  }
}

/// Rend `text` en arial48 puis upscale à `targetH` px (pour approcher 64px).
img.Image renderScaledText(String text, img.Color color, int targetH,
    {int spacing = 0}) {
  final font = img.arial48;
  final w = _stringWidth(font, text, spacing);
  final h = font.lineHeight;
  // Canvas temp avec marge top pour les ascendants
  final tmp = img.Image(width: w + 4, height: h + 4, numChannels: 4);
  drawSpacedText(tmp, text, font, x: 2, y: 2, color: color, spacing: spacing);
  if (targetH == h) return tmp;
  final scale = targetH / h;
  return img.copyResize(tmp,
      width: (tmp.width * scale).round(),
      height: (tmp.height * scale).round(),
      interpolation: img.Interpolation.cubic);
}

// ── Helpers fond ────────────────────────────────────────────────────────

img.Image makeCanvas(int w, int h, img.Color bg, {int radius = 0}) {
  final image = img.Image(width: w, height: h, numChannels: 4);
  if (radius > 0) {
    img.fillRect(image,
        x1: 0, y1: 0, x2: w - 1, y2: h - 1,
        color: bg, radius: radius);
  } else {
    img.fillRect(image,
        x1: 0, y1: 0, x2: w - 1, y2: h - 1, color: bg);
  }
  return image;
}

void compositeOnto(img.Image dst, img.Image src, int dx, int dy) {
  img.compositeImage(dst, src, dstX: dx, dstY: dy);
}

void savePng(img.Image image, String name) {
  final bytes = img.encodePng(image);
  final path = p.join(outDir, name);
  File(path).writeAsBytesSync(bytes);
  stdout.writeln('  OK $name  (${image.width}x${image.height})');
}

// ── Versions ────────────────────────────────────────────────────────────

void v1() {
  final image = makeCanvas(512, 512, night, radius: 100);
  drawLogo(image, 256, 210, 320, LogoTheme(
    shieldStroke:    primary,
    shieldStrokeW:   2.5,
    shieldFill:      withAlpha(83, 74, 183, 0.18),
    sabre:           gold,
    sabreW:          3,
    garde:           goldDark,
    gardeW:          3,
    circleStroke:    primary,
    circleStrokeW:   2,
    circleFill:      night,
    check:           white,
    checkW:          3,
  ));
  // "FORTRESS" 38px (approx via arial48 → 38px) letterSpacing 6 centré bas
  final txt = renderScaledText('FORTRESS', primary, 38, spacing: 6);
  compositeOnto(image, txt, (512 - txt.width) ~/ 2, 440 - txt.height ~/ 2);
  savePng(image, 'fortress_principale.png');
}

void v2() {
  final image = makeCanvas(900, 220, white);
  // Icône 200x200 fond night rx=44 à gauche
  final icon = makeCanvas(200, 200, night, radius: 44);
  drawLogo(icon, 100, 100, 180, LogoTheme(
    shieldStroke:    primary,
    shieldStrokeW:   2.5,
    shieldFill:      withAlpha(83, 74, 183, 0.18),
    sabre:           gold,
    sabreW:          3,
    garde:           goldDark,
    gardeW:          3,
    circleStroke:    primary,
    circleStrokeW:   2,
    circleFill:      night,
    check:           white,
    checkW:          3,
  ));
  compositeOnto(image, icon, 10, 10);
  // "Fortress" 64px → arial48 upscale, "POINT OF SALE" 20px → arial24
  final fortress = renderScaledText('Fortress', night, 64);
  // y=110 dans le spec = baseline approximative — on aligne le bas du texte
  compositeOnto(image, fortress, 255, 110 - (fortress.height * 0.85).round());
  drawSpacedText(image, 'POINT OF SALE', img.arial24,
      x: 258, y: 148 - 20, color: primary, spacing: 5);
  savePng(image, 'fortress_horizontal.png');
}

void v3() {
  final image = makeCanvas(900, 220, night);
  final icon = makeCanvas(200, 200, night, radius: 44);
  drawLogo(icon, 100, 100, 180, LogoTheme(
    shieldStroke:    primaryL,
    shieldStrokeW:   2.5,
    shieldFill:      withAlpha(123, 115, 212, 0.18),
    sabre:           goldL,
    sabreW:          3,
    garde:           goldDark,
    gardeW:          3,
    circleStroke:    primaryL,
    circleStrokeW:   2,
    circleFill:      night,
    check:           white,
    checkW:          3,
  ));
  compositeOnto(image, icon, 10, 10);
  final fortress = renderScaledText('Fortress', white, 64);
  compositeOnto(image, fortress, 255, 110 - (fortress.height * 0.85).round());
  drawSpacedText(image, 'POINT OF SALE', img.arial24,
      x: 258, y: 148 - 20, color: primaryL, spacing: 5);
  savePng(image, 'fortress_fond_sombre.png');
}

void v4() {
  final image = makeCanvas(1024, 1024, night, radius: 230);
  drawLogo(image, 512, 512, 820, LogoTheme(
    shieldStroke:    primaryL,
    shieldStrokeW:   8,
    shieldFill:      withAlpha(83, 74, 183, 0.20),
    sabre:           goldL,
    sabreW:          9,
    garde:           goldGuard,
    gardeW:          5,
    circleStroke:    primaryL,
    circleStrokeW:   4,
    circleFill:      night,
    check:           white,
    checkW:          6,
  ));
  savePng(image, 'fortress_app_icon.png');
}

void v5() {
  final image = makeCanvas(512, 512, primary, radius: 115);
  drawLogo(image, 256, 256, 400, LogoTheme(
    shieldStroke:    withAlpha(255, 255, 255, 0.35),
    shieldStrokeW:   8,
    shieldFill:      withAlpha(255, 255, 255, 0.10),
    sabre:           withAlpha(255, 255, 255, 0.9),
    sabreW:          5,
    garde:           withAlpha(255, 255, 255, 0.6),
    gardeW:          3,
    circleStroke:    withAlpha(255, 255, 255, 0.5),
    circleStrokeW:   3,
    circleFill:      withAlpha(255, 255, 255, 0.15),
    check:           white,
    checkW:          4,
  ));
  savePng(image, 'fortress_violet.png');
}

void v6() {
  final image = makeCanvas(512, 512, white, radius: 115);
  // Bordure #e0e0e0 — pas de paramètre direct sur fillRect, on overlay
  // un drawRect (contour 1px arrondi) après le fond.
  // Note : drawRect ne supporte pas radius 4.x → approximation via drawPolygon
  // sur un cercle approché — visible en bordure du logo. Pour rester
  // simple : on saute la bordure 2px (cosmétique) ou on dessine un
  // rounded rect à 2px d'écart en réutilisant fillRect d'une couleur
  // identique au fond avec radius+2. Skipped pour l'instant.
  drawLogo(image, 256, 256, 400, LogoTheme(
    shieldStroke:    night,
    shieldStrokeW:   8,
    shieldFill:      withAlpha(26, 26, 46, 0.06),
    sabre:           night,
    sabreW:          5,
    garde:           grey44,
    gardeW:          3,
    circleStroke:    night,
    circleStrokeW:   3,
    circleFill:      white,
    check:           night,
    checkW:          4,
  ));
  savePng(image, 'fortress_monochrome.png');
}

void main() {
  Directory(outDir).createSync(recursive: true);
  stdout.writeln('Generation logos Fortress (pure Dart, package:image) ...');
  v1(); v2(); v3(); v4(); v5(); v6();
  stdout.writeln('OK - 6 fichiers dans $outDir');
}
