import 'package:flutter/material.dart';

import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../shared/widgets/app_overflow_menu.dart';

// `RestoGreeting` a été SUPPRIMÉ (24/09/2026) : la salutation « Bienvenue,
// <prénom> 👋 » de la barre supérieure. Le tableau de bord porte déjà son
// en-tête dans le corps, et les autres écrans leur titre à gauche : la barre
// n'avait plus rien à dire.
//
// `RestoSearchField` a été SUPPRIMÉ (2026-08-07) : la recherche de la barre
// supérieure ne portait que sur les plats, mais s'affichait sur toutes les
// pages racine du restaurant — Commandes, Plan de salle, Finances — où elle
// n'avait rien à trouver. Le Menu a sa propre barre, à l'endroit où elle sert.

/// MENU DU COMPTE, à droite de la barre : le NOM en est le déclencheur.
///
/// Il y avait deux éléments côte à côte — le bloc identité (avatar, nom, rôle)
/// et un ⋮ qui ouvrait le menu. Le nom porte désormais un chevron et ouvre
/// lui-même le menu : un élément au lieu de deux.
///
/// LE RÔLE DESCEND DANS LE MENU, avec la boutique : « Admin · <boutique> » en
/// tête. C'est une information de configuration — elle n'a pas sa place en
/// permanence dans la barre — et savoir DANS QUELLE BOUTIQUE on est compte
/// autant que le rôle.
///
/// Les entrées (Compte, Aide, À propos) restent celles d'`AppOverflowMenu`,
/// qui reçoit seulement un déclencheur et un en-tête : aucune entrée n'est
/// recopiée ici.
class RestoAccountMenu extends StatelessWidget {
  final String shopId;
  final bool isAdmin;

  /// Barre MOBILE (lot Shell, 25/09/2026) : l'avatar seul pour déclencheur —
  /// le nom ne tient pas dans une AppBar de téléphone. Le menu, lui, est le
  /// même : « Admin · <boutique> » en tête.
  final bool compact;

  const RestoAccountMenu({
    super.key,
    required this.shopId,
    required this.isAdmin,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final user = LocalStorageService.getCurrentUser();
    final name = (user?.name ?? '').trim();
    final initial = name.isEmpty ? '?' : name.characters.first.toUpperCase();
    final shop = LocalStorageService.getShop(shopId)?.name.trim() ?? '';
    final role = isAdmin ? 'Admin' : 'Équipe';

    return AppOverflowMenu(
      shopId: shopId,
      header: Text(
        shop.isEmpty ? role : '$role · $shop',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
      ),
      trigger: Padding(
        // Compact (barre mobile) : 8 de marge autour de l'avatar de 32 — une
        // cible de 48 px au doigt (lot 2, `touch_target.dart`).
        padding: compact
            ? const EdgeInsets.all(8)
            : const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: cs.primary.withValues(alpha: 0.14),
              child: Text(initial,
                  style: AppTextStyles.bodySmBold.copyWith(color: cs.onSurface)),
            ),
            if (!compact) ...[
              const SizedBox(width: 9),
              Flexible(
                child: Text(
                  name.isEmpty ? 'Utilisateur' : name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.bodySmBold.copyWith(color: cs.onSurface),
                ),
              ),
              const SizedBox(width: 2),
              Icon(Icons.keyboard_arrow_down_rounded,
                  size: 18, color: AppColors.textSecondary),
            ],
          ],
        ),
      ),
    );
  }
}
