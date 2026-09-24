import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text_styles.dart';

/// Menu « 3 points » affiché à l'extrême droite de la topbar/AppBar, présent
/// globalement sur toutes les pages shell (mobile + desktop).
///
/// Items :
///   • Compte   → raccourci vers le profil utilisateur
///   • Aide     → page d'aide / FAQ + contact support
///   • À propos → infos application (version, éditeur, mentions)
///
/// `shopId` sert à construire les routes shell (`/shop/:shopId/...`).
class AppOverflowMenu extends StatelessWidget {
  final String shopId;

  /// Déclencheur à la place du ⋮. `null` (défaut) : le ⋮, comme partout.
  ///
  /// Le restaurant en ordinateur y passe son bloc identité (avatar, nom,
  /// chevron) : le nom devient le déclencheur, un élément au lieu de deux.
  final Widget? trigger;

  /// Ligne d'EN-TÊTE du menu, non cliquable, suivie d'un filet. `null`
  /// (défaut) : pas d'en-tête. Le restaurant y met « Admin · <boutique> ».
  final Widget? header;

  const AppOverflowMenu({
    super.key,
    required this.shopId,
    this.trigger,
    this.header,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: trigger == null ? 'Plus' : 'Compte',
      icon: trigger == null
          ? const Icon(Icons.more_vert_rounded, size: 24)
          : null,
      position: PopupMenuPosition.under,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12)),
      onSelected: (value) {
        switch (value) {
          case 'compte':
            context.push('/shop/$shopId/parametres/profile');
            break;
          case 'aide':
            context.push('/shop/$shopId/aide');
            break;
          case 'apropos':
            context.push('/shop/$shopId/apropos');
            break;
        }
      },
      itemBuilder: (_) => [
        if (header != null) ...[
          PopupMenuItem<String>(enabled: false, child: header!),
          const PopupMenuDivider(),
        ],
        const PopupMenuItem(
          value: 'compte',
          child: _MenuRow(
              icon: Icons.person_outline_rounded, label: 'Compte'),
        ),
        const PopupMenuItem(
          value: 'aide',
          child: _MenuRow(
              icon: Icons.help_outline_rounded, label: 'Aide'),
        ),
        const PopupMenuItem(
          value: 'apropos',
          child: _MenuRow(
              icon: Icons.info_outline_rounded, label: 'À propos'),
        ),
      ],
      child: trigger,
    );
  }
}

class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String label;
  const _MenuRow({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Icon(icon, size: 20, color: AppColors.primary),
      const SizedBox(width: 12),
      Text(label,
          style: AppTextStyles.body.copyWith(fontWeight: FontWeight.w600)),
    ]);
  }
}
