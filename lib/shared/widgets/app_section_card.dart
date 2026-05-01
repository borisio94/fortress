import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';

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
  Widget build(BuildContext context) => Container(
    padding: padding ?? const EdgeInsets.all(16),
    decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Container(width: 26, height: 26,
            decoration: BoxDecoration(
                color: (iconColor ?? AppColors.primary).withOpacity(0.12),
                borderRadius: BorderRadius.circular(7)),
            child: Icon(icon, size: 13, color: iconColor ?? AppColors.primary)),
        const SizedBox(width: 8),
        Expanded(child: Text(title, style: const TextStyle(
            fontSize: 14, fontWeight: FontWeight.w700,
            color: Color(0xFF0F172A)))),
        if (trailing != null) trailing!,
      ]),
      const SizedBox(height: 10),
      const Divider(height: 1, color: Color(0xFFF0F0F0)),
      const SizedBox(height: 12),
      ...children,
    ]),
  );
}
