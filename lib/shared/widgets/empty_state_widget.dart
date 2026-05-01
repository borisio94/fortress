import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import 'app_primary_button.dart';

/// État vide unifié — utilisé sur toutes les pages sans données.
///
/// Design de référence : page CRM (clients_page.dart). Toutes les autres
/// pages doivent passer par ce widget pour conserver une UX cohérente :
/// icône cerclée 72×72, titre, sous-titre, et bouton CTA optionnel
/// (`AppPrimaryButton` 220px de large) avec icône.
class EmptyStateWidget extends StatelessWidget {
  /// Icône principale affichée dans le cercle haut.
  final IconData icon;

  /// Titre court (1 ligne en général).
  final String title;

  /// Phrase d'explication / suggestion d'action.
  final String subtitle;

  /// Texte du bouton CTA. Si null, le bouton n'est pas affiché.
  final String? ctaLabel;

  /// Icône du bouton CTA (par défaut `Icons.add_rounded`).
  final IconData? ctaIcon;

  /// Action déclenchée par le bouton CTA. Requis si [ctaLabel] est fourni.
  final VoidCallback? onCta;

  /// Largeur du bouton CTA (par défaut 220px, comme la page CRM).
  final double ctaWidth;

  const EmptyStateWidget({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.ctaLabel,
    this.ctaIcon,
    this.onCta,
    this.ctaWidth = 220,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

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
                color: AppColors.primarySurface,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 34, color: AppColors.primary),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 13,
                color: cs.onSurface.withOpacity(0.6),
                height: 1.5,
              ),
            ),
            if (ctaLabel != null && onCta != null) ...[
              const SizedBox(height: 24),
              SizedBox(
                width: ctaWidth,
                child: AppPrimaryButton(
                  label: ctaLabel!,
                  icon: ctaIcon ?? Icons.add_rounded,
                  onTap: onCta!,
                  color: AppColors.primary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
