import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/auth_provider.dart';
import '../../core/theme/app_colors.dart';

/// ─────────────────────────────────────────────────────────────────────────
/// Switcher de langue — utilisable n'importe où dans l'app.
///
/// Variantes :
///   LanguageSwitcher()              → bouton pill FR | EN
///   LanguageSwitcher.icon()         → icône globe seule (AppBar)
///   LanguageSwitcher.dropdown()     → menu déroulant
///
/// Exemples :
/// ```dart
/// // Dans une AppBar
/// actions: [LanguageSwitcher.icon()]
///
/// // Dans la page login
/// LanguageSwitcher()
///
/// // Dans les paramètres
/// LanguageSwitcher.dropdown()
/// ```
/// ─────────────────────────────────────────────────────────────────────────

// ── Variante pill (FR | EN) ───────────────────────────────────────────────

class LanguageSwitcher extends ConsumerWidget {
  final Color? activeColor;
  final Color? inactiveColor;
  final Color? backgroundColor;

  const LanguageSwitcher({
    super.key,
    this.activeColor,
    this.inactiveColor,
    this.backgroundColor,
  });

  /// Icône globe pour AppBar
  static Widget icon({Color? color}) => _LangIcon(color: color);

  /// Menu déroulant pour la page paramètres
  static Widget dropdown({Color? textColor}) =>
      _LangDropdown(textColor: textColor);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(localeProvider);

    return Container(
      height: 32,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: backgroundColor ?? Colors.white.withOpacity(0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: AppColors.primary.withOpacity(0.2),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: supportedLocales.map((locale) {
          final isActive = locale.languageCode == current.languageCode;
          return _PillItem(
            label: localeLabel(locale),
            isActive: isActive,
            activeColor: activeColor ?? AppColors.primary,
            inactiveColor: inactiveColor,
            onTap: () => ref.read(localeProvider.notifier).setLocale(locale),
          );
        }).toList(),
      ),
    );
  }
}

class _PillItem extends StatelessWidget {
  final String label;
  final bool isActive;
  final Color activeColor;
  final Color? inactiveColor;
  final VoidCallback onTap;

  const _PillItem({
    required this.label,
    required this.isActive,
    required this.activeColor,
    required this.onTap,
    this.inactiveColor,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: isActive ? activeColor : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 200),
          style: TextStyle(
            fontSize: 12,
            fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
            color: isActive
                ? Colors.white
                : (inactiveColor ?? AppColors.primary.withOpacity(0.6)),
            letterSpacing: 0.5,
          ),
          child: Text(label),
        ),
      ),
    );
  }
}

// ── Variante icône globe pour AppBar ──────────────────────────────────────

class _LangIcon extends ConsumerWidget {
  final Color? color;
  const _LangIcon({this.color});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(localeProvider);
    return IconButton(
      tooltip: current.languageCode == 'fr' ? 'Switch to English' : 'Passer en français',
      icon: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.language, size: 18,
              color: color ?? AppColors.primary),
          const SizedBox(width: 4),
          Text(
            localeLabel(current),
            style: TextStyle(
              fontSize: 12, fontWeight: FontWeight.w700,
              color: color ?? AppColors.primary,
            ),
          ),
        ],
      ),
      onPressed: () => ref.read(localeProvider.notifier).toggle(),
    );
  }
}

// ── Variante dropdown pour page paramètres ────────────────────────────────

class _LangDropdown extends ConsumerWidget {
  final Color? textColor;
  const _LangDropdown({this.textColor});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(localeProvider);
    return Theme(
        data: Theme.of(context).copyWith(
          canvasColor: Colors.white,
          colorScheme: Theme.of(context).colorScheme.copyWith(
            surface: Colors.white,
            onSurface: const Color(0xFF1A1D2E),
          ),
        ),
        child: DropdownButton<Locale>(
          value: current,
          underline: const SizedBox.shrink(),
          dropdownColor: Colors.white,
          menuMaxHeight: 300,
          borderRadius: BorderRadius.circular(12),
          icon: Icon(Icons.keyboard_arrow_down,
              color: textColor ?? AppColors.primary, size: 18),
          items: supportedLocales.map((locale) {
            return DropdownMenuItem(
              value: locale,
              child: Text(
                _langFullName(locale),
                style: TextStyle(
                  fontSize: 14,
                  color: textColor ?? const Color(0xFF1A1D2E),
                  fontWeight: locale == current
                      ? FontWeight.w600
                      : FontWeight.normal,
                ),
              ),
            );
          }).toList(),
          onChanged: (locale) {
            if (locale != null) {
              ref.read(localeProvider.notifier).setLocale(locale);
            }
          },
        ));
  }

  String _langFullName(Locale l) => switch (l.languageCode) {
    'fr' => '🇫🇷  Français',
    'en' => '🇬🇧  English',
    _ => l.languageCode,
  };
}
