import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/theme/app_theme.dart';

/// Card de section avec icône + titre + contenu
/// Réutilisée dans product_form, parametres, etc.
class AppSectionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget? trailing;
  final List<Widget> children;
  final EdgeInsetsGeometry? padding;
  final Color? iconColor;

  const AppSectionCard({
    super.key,
    required this.title,
    required this.icon,
    this.trailing,
    required this.children,
    this.padding,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: padding ?? const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.semantic.borderSubtle)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 26, height: 26,
              decoration: BoxDecoration(
                  color: (iconColor ?? AppColors.primary).withValues(alpha:0.12),
                  borderRadius: BorderRadius.circular(7)),
              child: Icon(icon, size: 13, color: iconColor ?? AppColors.primary)),
          const SizedBox(width: 8),
          Expanded(child: Text(title, style: AppTextStyles.label.copyWith(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurface))),
          if (trailing != null) trailing!,
        ]),
        const SizedBox(height: 10),
        Divider(height: 1, color: theme.semantic.borderSubtle),
        const SizedBox(height: 12),
        ...children,
      ]),
    );
  }
}
