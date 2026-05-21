import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../storage/hive_boxes.dart';

/// Palette de couleurs runtime — sélectionnable depuis les paramètres.
/// Chaque palette propose un jeu cohérent de primary / light / dark / surface.
class ThemePalette {
  final String id;
  final String labelFr;
  final String labelEn;
  final Color primary;
  final Color primaryLight;
  final Color primaryDark;
  final Color primarySurface;
  final List<Color> previewGradient;

  const ThemePalette({
    required this.id,
    required this.labelFr,
    required this.labelEn,
    required this.primary,
    required this.primaryLight,
    required this.primaryDark,
    required this.primarySurface,
    required this.previewGradient,
  });

  String label(bool isFr) => isFr ? labelFr : labelEn;

  /// Sérialisation pour Hive — utilisée uniquement pour les palettes
  /// dynamiques (`id = logo_generated`). Les palettes du catalogue
  /// sont retrouvées par leur `id` via `paletteById` ; pas besoin de
  /// les sérialiser.
  Map<String, dynamic> toJson() => {
        'id':               id,
        'labelFr':          labelFr,
        'labelEn':          labelEn,
        'primary':          _toInt(primary),
        'primaryLight':     _toInt(primaryLight),
        'primaryDark':      _toInt(primaryDark),
        'primarySurface':   _toInt(primarySurface),
        'previewGradient':  previewGradient.map(_toInt).toList(),
      };

  static ThemePalette fromJson(Map<String, dynamic> j) => ThemePalette(
        id:             j['id'] as String,
        labelFr:        (j['labelFr'] as String?) ?? 'Votre logo',
        labelEn:        (j['labelEn'] as String?) ?? 'Your logo',
        primary:        _fromInt(j['primary']),
        primaryLight:   _fromInt(j['primaryLight']),
        primaryDark:    _fromInt(j['primaryDark']),
        primarySurface: _fromInt(j['primarySurface']),
        previewGradient: ((j['previewGradient'] as List?) ?? const [])
            .map((v) => _fromInt(v))
            .toList(growable: false),
      );

  static int _toInt(Color c) {
    final a = (c.a * 255).round() & 0xff;
    final r = (c.r * 255).round() & 0xff;
    final g = (c.g * 255).round() & 0xff;
    final b = (c.b * 255).round() & 0xff;
    return (a << 24) | (r << 16) | (g << 8) | b;
  }

  static Color _fromInt(dynamic v) {
    if (v is int) return Color(v);
    if (v is num) return Color(v.toInt());
    return const Color(0xFF000000);
  }
}

// ─── Thèmes disponibles ──────────────────────────────────────────────────────

const kDefaultPalette = _violet;

const _violet = ThemePalette(
  id: 'violet',
  labelFr: 'Violet Fortress',
  labelEn: 'Violet Fortress',
  primary:        Color(0xFF6C3FC7),
  primaryLight:   Color(0xFF8B5CF6),
  primaryDark:    Color(0xFF4C1D95),
  primarySurface: Color(0xFFF5F0FF),
  previewGradient: [Color(0xFF6C3FC7), Color(0xFF8B5CF6)],
);

const _ocean = ThemePalette(
  id: 'ocean',
  labelFr: 'Océan',
  labelEn: 'Ocean',
  primary:        Color(0xFF0EA5E9),
  primaryLight:   Color(0xFF38BDF8),
  primaryDark:    Color(0xFF0369A1),
  primarySurface: Color(0xFFEFF9FE),
  previewGradient: [Color(0xFF0EA5E9), Color(0xFF06B6D4)],
);

const _emerald = ThemePalette(
  id: 'emerald',
  labelFr: 'Émeraude',
  labelEn: 'Emerald',
  primary:        Color(0xFF10B981),
  primaryLight:   Color(0xFF34D399),
  primaryDark:    Color(0xFF047857),
  primarySurface: Color(0xFFECFDF5),
  previewGradient: [Color(0xFF10B981), Color(0xFF14B8A6)],
);

const _sunset = ThemePalette(
  id: 'sunset',
  labelFr: 'Coucher de soleil',
  labelEn: 'Sunset',
  primary:        Color(0xFFF97316),
  primaryLight:   Color(0xFFFB923C),
  primaryDark:    Color(0xFFC2410C),
  primarySurface: Color(0xFFFFF7ED),
  previewGradient: [Color(0xFFF97316), Color(0xFFEF4444)],
);

const _rose = ThemePalette(
  id: 'rose',
  labelFr: 'Rose',
  labelEn: 'Rose',
  primary:        Color(0xFFEC4899),
  primaryLight:   Color(0xFFF472B6),
  primaryDark:    Color(0xFFBE185D),
  primarySurface: Color(0xFFFDF2F8),
  previewGradient: [Color(0xFFEC4899), Color(0xFFF472B6)],
);

const _midnight = ThemePalette(
  id: 'midnight',
  labelFr: 'Minuit',
  labelEn: 'Midnight',
  primary:        Color(0xFF1E293B),
  primaryLight:   Color(0xFF475569),
  primaryDark:    Color(0xFF0F172A),
  primarySurface: Color(0xFFF1F5F9),
  previewGradient: [Color(0xFF1E293B), Color(0xFF475569)],
);

const _amber = ThemePalette(
  id: 'amber',
  labelFr: 'Ambre',
  labelEn: 'Amber',
  primary:        Color(0xFFD97706),
  primaryLight:   Color(0xFFF59E0B),
  primaryDark:    Color(0xFF92400E),
  primarySurface: Color(0xFFFEF3C7),
  previewGradient: [Color(0xFFD97706), Color(0xFFF59E0B)],
);

const _indigo = ThemePalette(
  id: 'indigo',
  labelFr: 'Indigo',
  labelEn: 'Indigo',
  primary:        Color(0xFF4F46E5),
  primaryLight:   Color(0xFF6366F1),
  primaryDark:    Color(0xFF3730A3),
  primarySurface: Color(0xFFEEF2FF),
  previewGradient: [Color(0xFF4F46E5), Color(0xFF8B5CF6)],
);

const kAllPalettes = <ThemePalette>[
  _violet, _ocean, _emerald, _sunset, _rose, _midnight, _amber, _indigo,
];

ThemePalette paletteById(String id) =>
    kAllPalettes.firstWhere((p) => p.id == id, orElse: () => _violet);

// ─── Provider Riverpod ──────────────────────────────────────────────────────

class ThemePaletteNotifier extends Notifier<ThemePalette> {
  static const _idKey         = 'app_theme_palette';
  /// Clé Hive — la palette générée depuis un logo doit persister son
  /// JSON complet (les 4 couleurs + gradient), pas seulement son id.
  /// Sinon, au boot suivant `paletteById('logo_generated')` retombe
  /// sur Violet car l'id n'existe pas dans `kAllPalettes`.
  static const _hiveCustomKey = 'logo_palette_cache';

  /// Id de la dernière palette manuelle (catalogue) sélectionnée.
  /// Sert au fallback quand l'utilisateur supprime son logo : on
  /// revient à sa préférence précédente plutôt qu'au Violet par
  /// défaut. `null` si l'utilisateur n'a jamais touché au sélecteur
  /// avant l'upload du logo.
  static const _idLastManualKey = 'app_theme_palette_last_manual';

  @override
  ThemePalette build() {
    _load();
    return kDefaultPalette;
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = prefs.getString(_idKey);
      if (id == null) return;
      if (id == 'logo_generated') {
        // Hydrate depuis le cache Hive (JSON complet) — sinon on
        // perdrait les couleurs car `paletteById` retomberait sur
        // Violet (id inconnu du catalogue).
        final raw = HiveBoxes.settingsBox.get(_hiveCustomKey);
        if (raw is String && raw.isNotEmpty) {
          try {
            final map = jsonDecode(raw) as Map<String, dynamic>;
            state = ThemePalette.fromJson(map);
            return;
          } catch (_) {/* fallback ci-dessous */}
        }
        // Cache absent / corrompu → on retombe sur Violet et on purge
        // l'id pour ne pas re-tenter à chaque boot.
        await prefs.remove(_idKey);
        return;
      }
      state = paletteById(id);
    } catch (_) {}
  }

  Future<void> setPalette(ThemePalette p) async {
    // Comparaison id+primary plutôt que id seul : la palette générée
    // depuis un logo porte toujours l'id `logo_generated` mais ses
    // couleurs changent à chaque upload différent. Sans cette nuance,
    // un changement de logo ne mettait pas à jour le thème (early
    // return sur l'id identique) et l'utilisateur ne voyait rien
    // bouger. On compare aussi `primary` pour préserver l'optim sur
    // les palettes catalogue (id unique = couleurs fixes).
    if (state.id == p.id && state.primary == p.primary) return;
    state = p;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_idKey, p.id);
      if (p.id == 'logo_generated') {
        // Persiste le JSON complet — `_load` ira le chercher au boot.
        await HiveBoxes.settingsBox
            .put(_hiveCustomKey, jsonEncode(p.toJson()));
      } else {
        // L'utilisateur choisit une palette catalogue → on tag cette
        // sélection comme « dernière préférence manuelle » pour le
        // fallback delete-logo.
        await prefs.setString(_idLastManualKey, p.id);
      }
    } catch (_) {}
  }

  /// Lecture synchrone du cache Hive — utilisée par le sélecteur de
  /// palette pour afficher la card « Généré depuis votre logo » sans
  /// avoir à passer par le notifier (et son state qui peut être autre
  /// chose qu'une logo_generated à un instant T).
  /// Retourne `null` si le cache est absent / corrompu.
  static ThemePalette? cachedLogoPalette() {
    try {
      if (!Hive.isBoxOpen(HiveBoxes.settings)) return null;
      final raw = HiveBoxes.settingsBox.get(_hiveCustomKey);
      if (raw is! String || raw.isEmpty) return null;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return ThemePalette.fromJson(map);
    } catch (_) {
      return null;
    }
  }

  /// Bascule explicitement sur la dernière palette manuelle stockée
  /// (ou Violet par défaut). Appelé par le flow « suppression de
  /// logo » dans `ShopLogoSection` — distinct de `setPalette` car
  /// on doit aussi purger le cache custom Hive.
  Future<void> resetToManualOrDefault() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastManual = prefs.getString(_idLastManualKey);
      final target = lastManual != null
          ? paletteById(lastManual)
          : kDefaultPalette;
      // Vide d'abord le cache pour que `_load` ne ressuscite pas
      // la palette générée au prochain boot.
      if (Hive.isBoxOpen(HiveBoxes.settings)) {
        await HiveBoxes.settingsBox.delete(_hiveCustomKey);
      }
      await setPalette(target);
    } catch (_) {}
  }
}

final themePaletteProvider =
    NotifierProvider<ThemePaletteNotifier, ThemePalette>(
        ThemePaletteNotifier.new);
