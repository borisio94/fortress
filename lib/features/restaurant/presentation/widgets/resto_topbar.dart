import 'package:flutter/material.dart';

import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_text_styles.dart';

/// Salutation « Bienvenue, <prénom> » de la barre supérieure restaurant.
class RestoGreeting extends StatelessWidget {
  const RestoGreeting({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final full = LocalStorageService.getCurrentUser()?.name.trim() ?? '';
    // Prénom seul : un nom complet déborderait sur la recherche en 1200 px.
    final first = full.isEmpty ? '' : full.split(RegExp(r'\s+')).first;

    return Text(
      first.isEmpty ? 'Bienvenue 👋' : 'Bienvenue, $first 👋',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: AppTextStyles.subtitleBold.copyWith(color: cs.onSurface),
    );
  }
}

// `RestoSearchField` a été SUPPRIMÉ (2026-08-07) : la recherche de la barre
// supérieure ne portait que sur les plats, mais s'affichait sur toutes les
// pages racine du restaurant — Commandes, Plan de salle, Finances — où elle
// n'avait rien à trouver. Le Menu a sa propre barre, à l'endroit où elle sert.

/// Bloc identité à droite de la barre : avatar, nom, rôle.
class RestoUserChip extends StatelessWidget {
  final bool isAdmin;

  const RestoUserChip({super.key, required this.isAdmin});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final user = LocalStorageService.getCurrentUser();
    final name = (user?.name ?? '').trim();
    final initial = name.isEmpty ? '?' : name.characters.first.toUpperCase();

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircleAvatar(
          radius: 16,
          backgroundColor: cs.primary.withValues(alpha: 0.14),
          child: Text(initial,
              style: AppTextStyles.bodySmBold.copyWith(color: cs.primary)),
        ),
        const SizedBox(width: 9),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              name.isEmpty ? 'Utilisateur' : name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.bodySmBold.copyWith(color: cs.onSurface),
            ),
            Text(isAdmin ? 'Admin' : 'Équipe',
                style: AppTextStyles.micro),
          ],
        ),
      ],
    );
  }
}
