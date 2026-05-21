import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../storage/hive_boxes.dart';
import '../theme/theme_palette.dart';

/// Extraction des 2 couleurs dominantes d'un logo + corrections pour
/// rester lisible sur fond clair de facture.
///
/// Algo : sampling pixels (1/N), clustering k-means k=2 sur RGB,
/// puis correction YIQ :
///   * YIQ > 200 → couleur quasi-blanche → forcer #1a1a1a (sinon
///     invisible sur fond facture #FAFAF8).
///   * YIQ < 40  → couleur quasi-noire → éclaircir ×1.4 pour qu'elle
///     ressorte (utile pour secondary qui sert au texte fin gris).
///
/// Sans logo : retourne le fallback (#1a1a1a, #555555). Le service est
/// idempotent — appelable à chaque upload, écrit le résultat dans la
/// `settingsBox` sous `logo_color_primary_<shopId>` /
/// `logo_color_secondary_<shopId>`.
class LogoColorExtractor {
  const LogoColorExtractor._();

  /// Couleurs par défaut (sombre/gris) — utilisées quand aucun logo
  /// n'est défini ou quand l'extraction échoue.
  static const Color defaultPrimary   = Color(0xFF1A1A1A);
  static const Color defaultSecondary = Color(0xFF555555);

  /// Nb maximal de pixels échantillonnés. Au-delà, on saute des pixels
  /// (stride proportionnel) — 5000 suffisent pour stabiliser k-means
  /// sur 2 clusters et garde l'extraction sous 100ms sur un logo 512px.
  static const int _maxSamples = 5000;
  static const int _kmeansIterations = 8;

  // ── API publique ────────────────────────────────────────────────

  /// Extrait les 2 couleurs dominantes de [bytes], applique les
  /// corrections YIQ, persiste dans Hive et retourne le couple.
  /// Retourne le fallback si [bytes] est null/invalide.
  static Future<({Color primary, Color secondary})> extractAndCache({
    required String shopId,
    Uint8List? bytes,
  }) async {
    if (bytes == null || bytes.isEmpty) {
      await _cache(shopId, defaultPrimary, defaultSecondary);
      return (primary: defaultPrimary, secondary: defaultSecondary);
    }
    try {
      final pair = _extractFromBytes(bytes);
      await _cache(shopId, pair.primary, pair.secondary);
      return pair;
    } catch (e) {
      debugPrint('[LogoColors] extraction échouée : $e');
      await _cache(shopId, defaultPrimary, defaultSecondary);
      return (primary: defaultPrimary, secondary: defaultSecondary);
    }
  }

  // ── Extraction THÈME (PR-2 — palette runtime) ─────────────────
  //
  // Méthode séparée de `extractAndCache` car les contraintes diffèrent :
  // pour la facture, on veut une couleur LISIBLE sur fond clair (YIQ
  // correction). Pour le thème, on veut la couleur la PLUS SATURÉE
  // disponible, avec validation WCAG AA contre le fond UI. Algos
  // distincts, mêmes pixels source.

  /// Extrait une `LogoPalette` exploitable par le builder de thème.
  /// Comportement spec :
  ///   * Top 5 couleurs dominantes (k=5 clustering pixels).
  ///   * Filtre luminance < 0.08 ou > 0.85 (trop sombres/claires).
  ///   * Tri par saturation desc → primary = +saturée, secondary = 2e.
  ///   * Ramp HSL 7 stops depuis primary (50, 100, 200, 400, 600, 800, 900).
  ///   * Validation WCAG AA : contraste ramp[800]/[900] vs ramp[50]
  ///     >= 4.5. Si échec → désaturer max 3 fois. Si toujours KO →
  ///     `nearestKAllPalette` (fallback vers une palette du catalogue).
  ///   * Saturation max < 0.1 → `isMonochrome = true`
  ///     (le caller bascule sur Midnight + snack).
  ///   * Erreur décodage / pixels insuffisants → `null` (le caller
  ///     laisse le thème inchangé — le logo reste OK pour la facture).
  ///
  /// `compute()` automatiquement déclenché si [bytes] > 500 KB pour
  /// ne pas bloquer l'UI thread (clustering sur grosses images ~80 ms).
  static Future<LogoPalette?> extractForTheme(Uint8List bytes) async {
    if (bytes.isEmpty) return null;
    try {
      // Au-delà de 500 KB, l'extraction prend > 100 ms et déclenche
      // un jank visible. On délègue à un isolate.
      if (bytes.length > _computeThreshold) {
        return await compute(_extractForThemeWorker, bytes);
      }
      return _extractForThemeWorker(bytes);
    } catch (e) {
      debugPrint('[LogoColors] extractForTheme : $e');
      return null;
    }
  }

  /// Seuil bytes au-delà duquel on bascule sur un isolate (`compute`)
  /// pour ne pas bloquer le main thread. ~500 KB couvre les logos
  /// haute résolution avant compression upload.
  static const int _computeThreshold = 500 * 1024;

  /// Lecture synchrone du cache. Retourne le fallback si absent —
  /// jamais d'exception, jamais de fetch.
  static ({Color primary, Color secondary}) cached(String shopId) {
    try {
      final p = HiveBoxes.settingsBox.get('logo_color_primary_$shopId');
      final s = HiveBoxes.settingsBox.get('logo_color_secondary_$shopId');
      return (
        primary:   p is int ? Color(p) : defaultPrimary,
        secondary: s is int ? Color(s) : defaultSecondary,
      );
    } catch (_) {
      return (primary: defaultPrimary, secondary: defaultSecondary);
    }
  }

  // ── Internals ──────────────────────────────────────────────────

  static ({Color primary, Color secondary}) _extractFromBytes(
      Uint8List bytes) {
    final image = img.decodeImage(bytes);
    if (image == null) {
      return (primary: defaultPrimary, secondary: defaultSecondary);
    }
    // Resize agressif pour accélérer le sampling (le détail couleur
    // est conservé même sur une petite image). 64×64 max = ~4000
    // pixels en mode portrait/paysage, idéal pour 2 clusters.
    final scaled = img.copyResize(
      image,
      width: image.width >= image.height ? 64 : null,
      height: image.height > image.width ? 64 : null,
      interpolation: img.Interpolation.average,
    );
    final samples = <_Rgb>[];
    for (final px in scaled) {
      // Skip pixels transparents (alpha < 32) — courants sur les logos
      // PNG sur fond transparent : ils tireraient le cluster vers
      // blanc/noir selon la composition.
      if (px.a < 32) continue;
      // Skip pixels quasi-blancs (proches du fond facture) pour ne pas
      // saturer le cluster « clair » et perdre la vraie couleur du logo.
      if (px.r > 240 && px.g > 240 && px.b > 240) continue;
      samples.add(_Rgb(px.r.toInt(), px.g.toInt(), px.b.toInt()));
      if (samples.length >= _maxSamples) break;
    }
    if (samples.length < 2) {
      return (primary: defaultPrimary, secondary: defaultSecondary);
    }
    final clusters = _kmeans2(samples);
    // L'ordre primary/secondary suit la TAILLE du cluster — la couleur
    // la plus présente dans le logo devient `primary` (souvent la
    // dominante des typo / pictos).
    final ordered = (clusters[0].size >= clusters[1].size)
        ? [clusters[0].center, clusters[1].center]
        : [clusters[1].center, clusters[0].center];
    final primary   = _correctYiq(ordered[0]);
    final secondary = _correctYiq(ordered[1]);
    return (primary: primary, secondary: secondary);
  }

  /// k-means k=2 simple. Initialisation : premier + plus éloigné (pour
  /// garantir 2 centres distincts dès le départ).
  static List<_Cluster> _kmeans2(List<_Rgb> samples) {
    var c1 = samples.first;
    _Rgb c2 = samples.first;
    double maxDist = -1;
    for (final p in samples) {
      final d = _dist(c1, p);
      if (d > maxDist) {
        maxDist = d;
        c2 = p;
      }
    }
    var members1 = <_Rgb>[];
    var members2 = <_Rgb>[];
    for (var i = 0; i < _kmeansIterations; i++) {
      members1 = <_Rgb>[];
      members2 = <_Rgb>[];
      for (final p in samples) {
        if (_dist(p, c1) <= _dist(p, c2)) {
          members1.add(p);
        } else {
          members2.add(p);
        }
      }
      if (members1.isEmpty || members2.isEmpty) break;
      final newC1 = _centroid(members1);
      final newC2 = _centroid(members2);
      if (newC1 == c1 && newC2 == c2) break;
      c1 = newC1;
      c2 = newC2;
    }
    return [
      _Cluster(center: c1, size: members1.length),
      _Cluster(center: c2, size: members2.length),
    ];
  }

  static double _dist(_Rgb a, _Rgb b) {
    final dr = a.r - b.r;
    final dg = a.g - b.g;
    final db = a.b - b.b;
    return (dr * dr + dg * dg + db * db).toDouble();
  }

  static _Rgb _centroid(List<_Rgb> list) {
    int sr = 0, sg = 0, sb = 0;
    for (final p in list) {
      sr += p.r;
      sg += p.g;
      sb += p.b;
    }
    final n = list.length;
    return _Rgb(sr ~/ n, sg ~/ n, sb ~/ n);
  }

  /// YIQ (luminance perçue) : 0.299·R + 0.587·G + 0.114·B → 0..255.
  ///   * > 200 : trop clair pour fond facture → on force noir doux.
  ///   * < 40  : trop sombre, illisible pour un secondary fin → on
  ///             éclaircit ×1.4 cap 255 par canal.
  static Color _correctYiq(_Rgb c) {
    final yiq = (c.r * 0.299 + c.g * 0.587 + c.b * 0.114);
    if (yiq > 200) {
      return const Color(0xFF1A1A1A);
    }
    if (yiq < 40) {
      final r = math.min(255, (c.r * 1.4).round());
      final g = math.min(255, (c.g * 1.4).round());
      final b = math.min(255, (c.b * 1.4).round());
      return Color.fromARGB(0xFF, r, g, b);
    }
    return Color.fromARGB(0xFF, c.r, c.g, c.b);
  }

  static Future<void> _cache(
      String shopId, Color primary, Color secondary) async {
    try {
      await HiveBoxes.settingsBox.put(
          'logo_color_primary_$shopId', _toInt(primary));
      await HiveBoxes.settingsBox.put(
          'logo_color_secondary_$shopId', _toInt(secondary));
    } catch (e) {
      debugPrint('[LogoColors] cache : $e');
    }
  }

  /// `Color.value` est deprecated dans les Flutter récents — on
  /// recompose via toARGB32 sur les nouvelles versions, fallback
  /// classique sinon. Ici on utilise l'écriture compatible.
  static int _toInt(Color c) {
    final a = (c.a * 255).round() & 0xff;
    final r = (c.r * 255).round() & 0xff;
    final g = (c.g * 255).round() & 0xff;
    final b = (c.b * 255).round() & 0xff;
    return (a << 24) | (r << 16) | (g << 8) | b;
  }
}

class _Rgb {
  final int r, g, b;
  const _Rgb(this.r, this.g, this.b);
  @override
  bool operator ==(Object o) =>
      o is _Rgb && o.r == r && o.g == g && o.b == b;
  @override
  int get hashCode => Object.hash(r, g, b);
}

class _Cluster {
  final _Rgb center;
  final int  size;
  const _Cluster({required this.center, required this.size});
}

// ════════════════════════════════════════════════════════════════════
// LogoPalette — résultat de l'extraction pour le thème runtime.
// Construit par `LogoColorExtractor.extractForTheme`, consommé par
// `LogoThemeBuilder.buildFromLogo`. Les `rampStops` sont les 7 nuances
// dérivées (50/100/200/400/600/800/900) sur lesquelles le builder
// pioche pour remplir primary/Light/Dark/Surface.
// ════════════════════════════════════════════════════════════════════
class LogoPalette {
  final Color primary;
  final Color secondary;
  /// Nuances HSL générées depuis primary. Clés normalisées Material
  /// Design (50 le plus clair, 900 le plus foncé).
  final Map<int, Color> rampStops;
  /// Saturation du primary après corrections. < 0.1 signifie logo
  /// quasi-monochrome (noir/blanc/gris) — le caller doit basculer
  /// sur Midnight et afficher un snack explicite.
  final bool isMonochrome;
  /// `true` quand la validation WCAG AA a échoué après désaturation
  /// et qu'on a basculé sur un fallback du catalogue `kAllPalettes`.
  /// Permet au caller de logger / journaliser le fallback.
  final bool fellBackToCatalog;
  /// Id de la palette `kAllPalettes` utilisée en fallback (si
  /// [fellBackToCatalog]). `null` sinon.
  final String? fallbackPaletteId;

  const LogoPalette({
    required this.primary,
    required this.secondary,
    required this.rampStops,
    this.isMonochrome      = false,
    this.fellBackToCatalog = false,
    this.fallbackPaletteId,
  });
}

// ════════════════════════════════════════════════════════════════════
// Worker top-level — exécuté soit sur main thread, soit dans un
// isolate via `compute()`. DOIT être une fonction top-level (pas de
// closure ni de méthode statique avec capture) pour être serializable.
// ════════════════════════════════════════════════════════════════════
LogoPalette? _extractForThemeWorker(Uint8List bytes) {
  final image = img.decodeImage(bytes);
  if (image == null) return null;
  // Resize 96px max — bon compromis vitesse / précision pour 5 clusters.
  final scaled = img.copyResize(
    image,
    width: image.width >= image.height ? 96 : null,
    height: image.height > image.width ? 96 : null,
    interpolation: img.Interpolation.average,
  );
  // Collecte des pixels exploitables. On skip :
  //  - alpha < 32 : transparence (fond du logo, non-couleur).
  //  - quasi-blanc (>240) : fond papier / cadre de logo, dilue
  //    artificiellement le cluster « clair ».
  //  - quasi-noir (<10)   : ombres et contours, idem côté foncé.
  final samples = <_Rgb>[];
  for (final px in scaled) {
    if (px.a < 32) continue;
    final r = px.r.toInt(), g = px.g.toInt(), b = px.b.toInt();
    if (r > 240 && g > 240 && b > 240) continue;
    if (r < 10  && g < 10  && b < 10)  continue;
    samples.add(_Rgb(r, g, b));
  }
  if (samples.length < 8) return null;
  // Top 5 clusters par k-means simple. Sur 96² ≈ 9000 px max après
  // filtres, ~5 itérations suffisent à stabiliser.
  final clusters = _kmeansK(samples, 5);
  // Conversion HSL puis filtre luminance.
  final hslList = <_Hsl>[];
  for (final c in clusters) {
    final hsl = _rgbToHsl(c.center);
    if (hsl.l < 0.08 || hsl.l > 0.85) continue;
    hslList.add(hsl);
  }
  if (hslList.isEmpty) return null;
  // Tri par saturation desc.
  hslList.sort((a, b) => b.s.compareTo(a.s));
  // Détection monochrome : aucune couleur du logo n'a une saturation
  // > 0.10. On retourne quand même une LogoPalette pour que le caller
  // détecte le cas et bascule sur Midnight (vs return null = erreur).
  if (hslList.first.s < 0.10) {
    return LogoPalette(
      primary:      _hslToColor(hslList.first),
      secondary:    _hslToColor(hslList.length > 1
          ? hslList[1] : hslList.first),
      rampStops:    const {},
      isMonochrome: true,
    );
  }
  var primaryHsl   = hslList.first;
  final secondaryHsl = hslList.length > 1 ? hslList[1] : hslList.first;
  // Génération du ramp 7 stops + validation WCAG. Si échec, on
  // désature primary jusqu'à 3 fois (réduit la saturation de 25 %
  // à chaque tentative) — empêche d'avoir un texte 800/900 illisible
  // sur fond surface 50.
  Map<int, Color> ramp = _buildRamp(primaryHsl);
  int attempt = 0;
  while (!_wcagOk(ramp) && attempt < 3) {
    primaryHsl = _Hsl(primaryHsl.h, primaryHsl.s * 0.75, primaryHsl.l);
    ramp = _buildRamp(primaryHsl);
    attempt++;
  }
  if (!_wcagOk(ramp)) {
    // Aucun ramp dérivé du logo ne passe — fallback catalogue.
    // On choisit la palette `kAllPalettes` dont primary est la plus
    // proche en HSL pour rester visuellement cohérente avec le logo.
    final nearest = _nearestCatalogPalette(primaryHsl);
    final nearestHsl = _rgbToHsl(_colorToRgb(nearest.primary));
    return LogoPalette(
      primary:           nearest.primary,
      secondary:         nearest.primaryLight,
      rampStops:         _buildRamp(nearestHsl),
      fellBackToCatalog: true,
      fallbackPaletteId: nearest.id,
    );
  }
  return LogoPalette(
    primary:    _hslToColor(primaryHsl),
    secondary:  _hslToColor(secondaryHsl),
    rampStops:  ramp,
  );
}

// ── k-means k=N (générique) ─────────────────────────────────────────
// Variante du k-means existant pour 2 clusters. Initialisation
// farthest-first (k++) — garantit que les centres initiaux sont aussi
// éloignés que possible, ce qui stabilise la convergence sans faire
// plusieurs runs.
List<_Cluster> _kmeansK(List<_Rgb> samples, int k) {
  if (samples.length <= k) {
    return [for (final s in samples) _Cluster(center: s, size: 1)];
  }
  final centers = <_Rgb>[samples.first];
  for (var i = 1; i < k; i++) {
    var farthest = samples.first;
    double maxMin = -1;
    for (final p in samples) {
      double minDist = double.infinity;
      for (final c in centers) {
        final d = _distSquared(p, c);
        if (d < minDist) minDist = d;
      }
      if (minDist > maxMin) {
        maxMin   = minDist;
        farthest = p;
      }
    }
    centers.add(farthest);
  }
  final members = List<List<_Rgb>>.generate(k, (_) => <_Rgb>[]);
  const maxIter = 8;
  for (var iter = 0; iter < maxIter; iter++) {
    for (var i = 0; i < k; i++) {
      members[i].clear();
    }
    for (final p in samples) {
      int best = 0;
      double bestDist = double.infinity;
      for (var i = 0; i < k; i++) {
        final d = _distSquared(p, centers[i]);
        if (d < bestDist) {
          bestDist = d;
          best     = i;
        }
      }
      members[best].add(p);
    }
    bool moved = false;
    for (var i = 0; i < k; i++) {
      if (members[i].isEmpty) continue;
      final c = _centroidOf(members[i]);
      if (c != centers[i]) {
        centers[i] = c;
        moved = true;
      }
    }
    if (!moved) break;
  }
  return [
    for (var i = 0; i < k; i++)
      if (members[i].isNotEmpty)
        _Cluster(center: centers[i], size: members[i].length),
  ];
}

double _distSquared(_Rgb a, _Rgb b) {
  final dr = a.r - b.r;
  final dg = a.g - b.g;
  final db = a.b - b.b;
  return (dr * dr + dg * dg + db * db).toDouble();
}

_Rgb _centroidOf(List<_Rgb> list) {
  int sr = 0, sg = 0, sb = 0;
  for (final p in list) {
    sr += p.r;
    sg += p.g;
    sb += p.b;
  }
  final n = list.length;
  return _Rgb(sr ~/ n, sg ~/ n, sb ~/ n);
}

// ── HSL helpers ────────────────────────────────────────────────────

class _Hsl {
  final double h, s, l;
  const _Hsl(this.h, this.s, this.l);
}

_Hsl _rgbToHsl(_Rgb c) {
  final r = c.r / 255.0;
  final g = c.g / 255.0;
  final b = c.b / 255.0;
  final maxV = math.max(r, math.max(g, b));
  final minV = math.min(r, math.min(g, b));
  final l = (maxV + minV) / 2;
  double h, s;
  if (maxV == minV) {
    h = 0;
    s = 0;
  } else {
    final d = maxV - minV;
    s = l > 0.5 ? d / (2 - maxV - minV) : d / (maxV + minV);
    if (maxV == r) {
      h = (g - b) / d + (g < b ? 6 : 0);
    } else if (maxV == g) {
      h = (b - r) / d + 2;
    } else {
      h = (r - g) / d + 4;
    }
    h /= 6;
  }
  return _Hsl(h, s, l);
}

Color _hslToColor(_Hsl hsl) {
  final r = _hslChannel(hsl, _Channel.r);
  final g = _hslChannel(hsl, _Channel.g);
  final b = _hslChannel(hsl, _Channel.b);
  return Color.fromARGB(0xFF, r, g, b);
}

_Rgb _colorToRgb(Color c) {
  final r = (c.r * 255).round() & 0xff;
  final g = (c.g * 255).round() & 0xff;
  final b = (c.b * 255).round() & 0xff;
  return _Rgb(r, g, b);
}

enum _Channel { r, g, b }

int _hslChannel(_Hsl hsl, _Channel ch) {
  final h = hsl.h, s = hsl.s, l = hsl.l;
  if (s == 0) return (l * 255).round();
  final q = l < 0.5 ? l * (1 + s) : l + s - l * s;
  final p = 2 * l - q;
  double t;
  switch (ch) {
    case _Channel.r: t = h + 1 / 3; break;
    case _Channel.g: t = h; break;
    case _Channel.b: t = h - 1 / 3; break;
  }
  if (t < 0) t += 1;
  if (t > 1) t -= 1;
  double v;
  if (t < 1 / 6) {
    v = p + (q - p) * 6 * t;
  } else if (t < 1 / 2) {
    v = q;
  } else if (t < 2 / 3) {
    v = p + (q - p) * (2 / 3 - t) * 6;
  } else {
    v = p;
  }
  return (v * 255).round();
}

// ── Ramp 7 stops + WCAG ───────────────────────────────────────────

const Map<int, double> _stopLightness = {
  50:  0.95,
  100: 0.88,
  200: 0.78,
  400: 0.60,
  600: 0.50,  // valeur de référence — ajustée par la luminance du primary
  800: 0.30,
  900: 0.18,
};

Map<int, Color> _buildRamp(_Hsl primary) {
  final out = <int, Color>{};
  _stopLightness.forEach((stop, lightness) {
    // Pour le stop 600, on garde la luminance du primary original
    // (sinon on perd la couleur ref choisie par l'utilisateur).
    final l = stop == 600 ? primary.l : lightness;
    // Pour les stops très clairs (50, 100) on réduit la saturation —
    // sinon le « surface » devient rose pétant ou cyan flashy.
    final s = stop <= 100
        ? primary.s * 0.35
        : stop <= 200 ? primary.s * 0.60 : primary.s;
    out[stop] = _hslToColor(_Hsl(primary.h, s, l));
  });
  return out;
}

/// WCAG AA exige un ratio de contraste >= 4.5 pour du texte normal.
/// On valide le texte foncé (800, 900) contre le surface (50) —
/// les deux usages les plus critiques de la palette.
bool _wcagOk(Map<int, Color> ramp) {
  final surface = ramp[50];
  final dark    = ramp[800];
  final deeper  = ramp[900];
  if (surface == null || dark == null || deeper == null) return false;
  final ratio800 = _contrastRatio(dark, surface);
  final ratio900 = _contrastRatio(deeper, surface);
  return ratio800 >= 4.5 && ratio900 >= 4.5;
}

double _relativeLuminance(Color c) {
  double channel(double v) {
    final s = v;
    return s <= 0.03928 ? s / 12.92 : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
  }
  final r = channel(c.r);
  final g = channel(c.g);
  final b = channel(c.b);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

double _contrastRatio(Color a, Color b) {
  final la = _relativeLuminance(a);
  final lb = _relativeLuminance(b);
  final lighter = math.max(la, lb);
  final darker  = math.min(la, lb);
  return (lighter + 0.05) / (darker + 0.05);
}

ThemePalette _nearestCatalogPalette(_Hsl primary) {
  ThemePalette best   = kAllPalettes.first;
  double bestDist     = double.infinity;
  for (final p in kAllPalettes) {
    final hsl = _rgbToHsl(_colorToRgb(p.primary));
    // Distance HSL : on pondère la teinte (h) à 2x pour préférer une
    // palette de même famille chromatique vs une saturation proche.
    double hueDiff = (hsl.h - primary.h).abs();
    if (hueDiff > 0.5) hueDiff = 1 - hueDiff;
    final d = hueDiff * 2 +
              (hsl.s - primary.s).abs() +
              (hsl.l - primary.l).abs();
    if (d < bestDist) {
      bestDist = d;
      best     = p;
    }
  }
  return best;
}
