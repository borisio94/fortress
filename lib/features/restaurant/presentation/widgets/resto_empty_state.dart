import 'package:flutter/material.dart';

import '../../../../core/theme/app_text_styles.dart';

/// État vide des écrans du module restaurant.
///
/// Écrit ici plutôt que via `EmptyStateWidget` : le bouton de ce dernier
/// n'est pas centré (padding H10/V3 dans une largeur fixe de 220), et il est
/// partagé avec l'e-commerce — le corriger à la source changerait des écrans
/// hors du périmètre restaurant.
class RestoEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  /// Libellé du bouton. `null` → aucun bouton (écran informatif seul).
  final String? actionLabel;
  final VoidCallback? onAction;

  const RestoEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: cs.primary.withValues(alpha: 0.10),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 30, color: cs.primary),
            ),
            const SizedBox(height: 16),
            Text(title,
                textAlign: TextAlign.center,
                style:
                    AppTextStyles.subtitleBold.copyWith(color: cs.onSurface)),
            const SizedBox(height: 8),
            Text(subtitle,
                textAlign: TextAlign.center,
                style: AppTextStyles.bodySecondary),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 24),
              Material(
                color: cs.primary,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  onTap: onAction,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    // Padding vertical de 10, contenu centré.
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.add_rounded, size: 18, color: cs.onPrimary),
                        const SizedBox(width: 8),
                        Text(actionLabel!,
                            style: AppTextStyles.bodySmBold
                                .copyWith(color: cs.onPrimary)),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
