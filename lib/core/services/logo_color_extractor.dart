import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../storage/hive_boxes.dart';

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
