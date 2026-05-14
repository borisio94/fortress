import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widgets/fortress_logo.dart';

// ═════════════════════════════════════════════════════════════════════════════
// PublicTopBar — barre haute des pages publiques (landing `/`, pricing
// `/pricing`). Logo Fortress à gauche + bouton "Connexion" à droite.
// Responsive : même layout mobile/desktop (compact, jamais drawer).
//
// Volontairement séparée de l'AppBar habituelle de l'app (qui dépend du
// shell authentifié et du dashboard view filter). Cette barre est public,
// statique, sans dépendance à un état utilisateur.
// ═════════════════════════════════════════════════════════════════════════════

class PublicTopBar extends StatelessWidget implements PreferredSizeWidget {
  /// Affiche un highlight discret sur le lien actif de la nav.
  final String? currentRoute;

  const PublicTopBar({super.key, this.currentRoute});

  @override
  Size get preferredSize => const Size.fromHeight(64);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      elevation: 0,
      child: Container(
        height: 64,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
                color: theme.colorScheme.outline.withValues(alpha: 0.15),
                width: 1),
          ),
        ),
        child: Row(children: [
          // Logo + nom marque cliquable → retour landing
          InkWell(
            onTap: () => context.go('/'),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 6, vertical: 4),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const FortressLogo.light(size: 32),
                const SizedBox(width: 10),
                Text('Fortress',
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: theme.colorScheme.onSurface)),
              ]),
            ),
          ),
          const Spacer(),
          // Nav links — pricing seulement (FAQ et autres dans la landing
          // sont scroll-anchors, pas de page dédiée pour l'instant).
          _NavLink(
            label: 'Tarifs',
            active: currentRoute == RouteNames.pricing,
            onTap: () => context.go(RouteNames.pricing),
          ),
          const SizedBox(width: 8),
          // CTA "Connexion" — outlined pour rester discret face au CTA
          // primaire "Essayer 14j gratuit" dans le hero.
          OutlinedButton(
            onPressed: () => context.go(RouteNames.login),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.primary,
              side: BorderSide(
                  color: AppColors.primary.withValues(alpha: 0.4)),
              padding: const EdgeInsets.symmetric(
                  horizontal: 18, vertical: 10),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Connexion',
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w700)),
          ),
        ]),
      ),
    );
  }
}

class _NavLink extends StatelessWidget {
  final String       label;
  final bool         active;
  final VoidCallback onTap;
  const _NavLink({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: 12, vertical: 8),
        child: Text(label,
            style: TextStyle(
                fontSize: 13,
                fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                color: active
                    ? AppColors.primary
                    : theme.colorScheme.onSurface.withValues(alpha: 0.75))),
      ),
    );
  }
}
