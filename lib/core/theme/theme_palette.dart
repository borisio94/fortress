import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  static const _key = 'app_theme_palette';

  @override
  ThemePalette build() {
    _load();
    return kDefaultPalette;
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = prefs.getString(_key);
      if (id != null) state = paletteById(id);
    } catch (_) {}
  }

  Future<void> setPalette(ThemePalette p) async {
    if (state.id == p.id) return;
    state = p;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, p.id);
    } catch (_) {}
  }
}

final themePaletteProvider =
    NotifierProvider<ThemePaletteNotifier, ThemePalette>(
        ThemePaletteNotifier.new);
