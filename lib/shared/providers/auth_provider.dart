import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../features/auth/domain/entities/user.dart';
import '../../core/storage/secure_storage.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Auth state — Riverpod 2.x
// ─────────────────────────────────────────────────────────────────────────────

class AuthStateData {
  final bool isAuthenticated;
  final User? user;
  const AuthStateData({required this.isAuthenticated, this.user});
}

final authStateProvider =
NotifierProvider<AuthNotifier, AuthStateData>(AuthNotifier.new);

class AuthNotifier extends Notifier<AuthStateData> {
  @override
  AuthStateData build() {
    _checkAuth();
    return const AuthStateData(isAuthenticated: false);
  }

  Future<void> _checkAuth() async {
    final token = await SecureStorageService.getAccessToken();
    state = AuthStateData(isAuthenticated: token != null && token.isNotEmpty);
  }

  void setUser(User user) =>
      state = AuthStateData(isAuthenticated: true, user: user);
  void logout() => state = const AuthStateData(isAuthenticated: false);
}

// ─────────────────────────────────────────────────────────────────────────────
// Locale — Riverpod 2.x
// ─────────────────────────────────────────────────────────────────────────────

const supportedLocales = [Locale('fr'), Locale('en')];

const _localeLabels = {'fr': 'FR', 'en': 'EN'};

String localeLabel(Locale locale) =>
    _localeLabels[locale.languageCode] ??
        locale.languageCode.toUpperCase();

final localeProvider =
NotifierProvider<LocaleNotifier, Locale>(LocaleNotifier.new);

class LocaleNotifier extends Notifier<Locale> {
  static const _prefKey = 'app_locale';

  @override
  Locale build() {
    _load();
    return const Locale('fr');
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_prefKey);
      if (saved != null &&
          supportedLocales.any((l) => l.languageCode == saved)) {
        state = Locale(saved);
      }
    } catch (_) {}
  }

  Future<void> toggle() async {
    final idx = supportedLocales
        .indexWhere((l) => l.languageCode == state.languageCode);
    final next = supportedLocales[(idx + 1) % supportedLocales.length];
    state = next;
    await _persist(next);
  }

  Future<void> setLocale(Locale locale) async {
    if (state == locale) return;
    state = locale;
    await _persist(locale);
  }

  Future<void> _persist(Locale locale) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, locale.languageCode);
    } catch (_) {}
  }
}