import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/language_switcher.dart';
import '../../../../shared/providers/auth_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/i18n/app_localizations.dart';

class LanguagePage extends ConsumerWidget {
  final String? shopId;
  const LanguagePage({super.key, this.shopId});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l      = context.l10n;
    final locale = ref.watch(localeProvider);
    return AppScaffold(
      shopId: shopId ?? '', title: l.paramLanguage, isRootPage: false,
      body: ListView(padding: const EdgeInsets.all(16), children: [
        ...supportedLocales.map((loc) => Container(
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: loc == locale ? AppColors.primary : const Color(0xFFE5E7EB),
              width: loc == locale ? 1.5 : 1,
            ),
          ),
          child: ListTile(
            leading: Text(loc.languageCode == 'fr' ? '🇫🇷' : '🇬🇧',
                style: const TextStyle(fontSize: 24)),
            title: Text(
              loc.languageCode == 'fr' ? 'Français' : 'English',
              style: TextStyle(
                fontWeight: loc == locale ? FontWeight.w700 : FontWeight.normal,
                color: loc == locale ? AppColors.primary : const Color(0xFF1A1D2E),
              ),
            ),
            subtitle: Text(
              loc.languageCode == 'fr' ? 'Langue française' : 'English language',
              style: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
            ),
            trailing: loc == locale
                ? Icon(Icons.check_circle, color: AppColors.primary, size: 20)
                : null,
            onTap: () => ref.read(localeProvider.notifier).setLocale(loc),
          ),
        )),
      ]),
    );
  }
}
